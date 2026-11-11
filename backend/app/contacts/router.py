"""Trusted contacts (P2-W2).

Adding a contact: the owner creates an invite and shares the link from their own phone; the
contact signs in and accepts. The server never sees the contact's phone number or name.
Contacts have no endpoint that lists the people they watch over (rule 4), so removal stays
silent: the row is deleted and nothing is sent to the contact.
"""

import base64
import logging
import uuid
from datetime import UTC, datetime, timedelta

from fastapi import APIRouter, HTTPException, Response, status
from sqlalchemy import and_, delete, func, or_, select
from sqlalchemy.exc import IntegrityError

from app.contacts import schemas
from app.contacts.models import TrustedContact
from app.core import audit
from app.identity import security
from app.identity.models import Device, DeviceE2EKeys
from app.identity.router import CurrentSessionDep, DbDep, RedisDep, SettingsDep

router = APIRouter(prefix="/contacts", tags=["contacts"])
log = logging.getLogger(__name__)

_INVITE_INVALID = HTTPException(status.HTTP_404_NOT_FOUND, "invite_invalid")
_NOT_FOUND = HTTPException(status.HTTP_404_NOT_FOUND, "contact_not_found")


def _invite_hash(secret: str, token: str) -> bytes:
    return bytes.fromhex(security.keyed_hash(secret, "contact-invite", token))


def _owned_link(db: DbDep, owner_id: uuid.UUID, link_id: uuid.UUID) -> TrustedContact:
    link = db.get(TrustedContact, link_id)
    if link is None or link.owner_id != owner_id:
        raise _NOT_FOUND
    return link


@router.post("/invites", status_code=status.HTTP_201_CREATED, response_model=schemas.Invite)
def create_invite(
    body: schemas.InviteCreate,
    session: CurrentSessionDep,
    settings: SettingsDep,
    redis: RedisDep,
    db: DbDep,
) -> schemas.Invite:
    """Create a one-time invite link for the owner to share (WhatsApp, SMS...) from their phone."""
    rate_key = f"rl:invite:{session.account_id}"
    redis.set(rate_key, 0, ex=3600, nx=True)
    if int(redis.incr(rate_key)) > settings.contact_invites_per_hour:
        raise HTTPException(
            status.HTTP_429_TOO_MANY_REQUESTS, "rate_limited", headers={"Retry-After": "3600"}
        )

    now = datetime.now(UTC)
    db.execute(
        delete(TrustedContact).where(
            TrustedContact.owner_id == session.account_id,
            TrustedContact.contact_id.is_(None),
            TrustedContact.invite_expires_at <= now,
        )
    )
    in_use = db.scalar(
        select(func.count())
        .select_from(TrustedContact)
        .where(TrustedContact.owner_id == session.account_id)
    )
    if in_use >= settings.max_trusted_contacts:
        db.rollback()
        raise HTTPException(status.HTTP_409_CONFLICT, "contact_limit_reached")

    token = security.new_token()
    link = TrustedContact(
        owner_id=session.account_id,
        owner_label=body.owner_label,
        invite_hash=_invite_hash(settings.token_secret, token),
        invite_expires_at=now + timedelta(seconds=settings.contact_invite_ttl_seconds),
    )
    db.add(link)
    db.flush()
    audit.record(db, "contact.invite_created", actor=session.account_id, target=f"link:{link.id}")
    db.commit()
    return schemas.Invite(
        contact_link_id=link.id,
        invite_token=token,
        invite_url=f"{settings.invite_base_url}#{token}",
        expires_at=link.invite_expires_at,
    )


@router.post("/invites/accept", response_model=schemas.InviteAccepted)
def accept_invite(
    body: schemas.InviteAccept, session: CurrentSessionDep, settings: SettingsDep, db: DbDep
) -> schemas.InviteAccepted:
    """The contact accepts. Accepting the same invite again is a no-op."""
    link = db.scalars(
        select(TrustedContact).where(
            TrustedContact.invite_hash == _invite_hash(settings.token_secret, body.invite_token)
        )
    ).first()
    if link is None:
        raise _INVITE_INVALID
    if link.contact_id == session.account_id:
        return schemas.InviteAccepted(owner_label=link.owner_label)
    if link.contact_id is not None or link.invite_expires_at <= datetime.now(UTC):
        raise _INVITE_INVALID
    if link.owner_id == session.account_id:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "cannot_add_self")

    existing = db.scalars(
        select(TrustedContact).where(
            TrustedContact.owner_id == link.owner_id,
            TrustedContact.contact_id == session.account_id,
        )
    ).first()
    if existing is not None:
        # Already this owner's contact: drop the duplicate pending invite.
        db.delete(link)
        db.commit()
        return schemas.InviteAccepted(owner_label=existing.owner_label)

    link.contact_id = session.account_id
    link.accepted_at = datetime.now(UTC)
    audit.record(db, "contact.accepted", actor=session.account_id, target=f"link:{link.id}")
    try:
        db.commit()
    except IntegrityError as exc:  # accepted a second invite from the same owner concurrently
        db.rollback()
        raise _INVITE_INVALID from exc
    log.info("contact invite accepted")
    return schemas.InviteAccepted(owner_label=link.owner_label)


@router.get("", response_model=schemas.ContactList)
def list_contacts(session: CurrentSessionDep, db: DbDep) -> schemas.ContactList:
    """The owner's own contacts. No contact details: the phone maps each id to its local entry."""
    links = db.scalars(
        select(TrustedContact)
        .where(
            TrustedContact.owner_id == session.account_id,
            or_(
                TrustedContact.contact_id.is_not(None),
                TrustedContact.invite_expires_at > datetime.now(UTC),
            ),
        )
        .order_by(TrustedContact.created_at)
    )
    return schemas.ContactList(
        contacts=[
            schemas.ContactLink(
                id=link.id,
                status="accepted" if link.contact_id else "pending",
                created_at=link.created_at,
                accepted_at=link.accepted_at,
                invite_expires_at=None if link.contact_id else link.invite_expires_at,
            )
            for link in links
        ]
    )


@router.delete("/{link_id}", status_code=status.HTTP_204_NO_CONTENT)
def remove_contact(link_id: uuid.UUID, session: CurrentSessionDep, db: DbDep) -> Response:
    """Silent removal: the link is deleted and the contact is never told."""
    link = _owned_link(db, session.account_id, link_id)
    db.delete(link)
    audit.record(db, "contact.removed", actor=session.account_id, target=f"link:{link_id}")
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/{link_id}/keys", response_model=schemas.ContactKeys)
def contact_keys(link_id: uuid.UUID, session: CurrentSessionDep, db: DbDep) -> schemas.ContactKeys:
    """E2E public keys of an accepted contact's active devices, for encrypting location to them."""
    link = _owned_link(db, session.account_id, link_id)
    if link.contact_id is None:
        raise _NOT_FOUND
    rows = db.scalars(
        select(DeviceE2EKeys)
        .join(Device, and_(Device.id == DeviceE2EKeys.device_id, Device.revoked_at.is_(None)))
        .where(Device.account_id == link.contact_id)
        .order_by(DeviceE2EKeys.updated_at)
    )
    return schemas.ContactKeys(
        contact_link_id=link.id,
        keys=[
            schemas.ContactKey(
                key_id=row.key_id,
                x25519_public_key=base64.b64encode(row.x25519_public_key).decode(),
                ed25519_public_key=base64.b64encode(row.ed25519_public_key).decode(),
            )
            for row in rows
        ],
    )
