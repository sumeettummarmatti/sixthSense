"""Who is coming to help (P3-W1): trusted contacts who said "I'm on it" and verified responders
who said "I'm going". The traveller sees them and their live location; each helper sees only the
traveller. Everything here is scoped to open alerts (rule 4)."""

import base64
import uuid
from datetime import datetime

from sqlalchemy import and_, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.contacts.models import TrustedContact
from app.core import audit
from app.escalation import schemas
from app.escalation.models import Escalation, EscalationHelper
from app.identity.models import Device, DeviceE2EKeys
from app.matching.models import ResponderProfile


def add(
    db: Session, escalation: Escalation, account_id: uuid.UUID, kind: str, now: datetime
) -> None:
    created = db.scalar(
        insert(EscalationHelper)
        .values(escalation_id=escalation.id, account_id=account_id, kind=kind, accepted_at=now)
        .on_conflict_do_nothing(constraint="uq_escalation_helpers_account")
        .returning(EscalationHelper.id)
    )
    if created is not None:
        audit.record(
            db, f"helper.going.{kind}", actor=account_id, target=f"escalation:{escalation.id}"
        )


def mark_arrived(
    db: Session, escalation_id: uuid.UUID, account_id: uuid.UUID, now: datetime
) -> bool:
    helper = db.scalars(
        select(EscalationHelper).where(
            EscalationHelper.escalation_id == escalation_id,
            EscalationHelper.account_id == account_id,
        )
    ).first()
    if helper is None:
        return False
    if helper.status != "arrived":
        helper.status, helper.arrived_at = "arrived", now
        audit.record(db, "helper.arrived", actor=account_id, target=f"escalation:{escalation_id}")
    return True


def _open_helpers(db: Session, journey_id: uuid.UUID):
    return db.execute(
        select(EscalationHelper, Escalation)
        .join(Escalation, Escalation.id == EscalationHelper.escalation_id)
        .where(Escalation.journey_id == journey_id, Escalation.closed_at.is_(None))
        .order_by(EscalationHelper.accepted_at)
    ).all()


def helper_accounts(db: Session, journey_id: uuid.UUID, kind: str | None = None) -> set[uuid.UUID]:
    """Accounts helping with an open alert on this journey."""
    return {
        helper.account_id
        for helper, _ in _open_helpers(db, journey_id)
        if kind is None or helper.kind == kind
    }


def device_keys(db: Session, account_id: uuid.UUID) -> list[schemas.HelperKey]:
    rows = db.scalars(
        select(DeviceE2EKeys)
        .join(Device, and_(Device.id == DeviceE2EKeys.device_id, Device.revoked_at.is_(None)))
        .where(Device.account_id == account_id)
        .order_by(DeviceE2EKeys.updated_at)
    )
    return [
        schemas.HelperKey(
            key_id=row.key_id,
            x25519_public_key=base64.b64encode(row.x25519_public_key).decode(),
            ed25519_public_key=base64.b64encode(row.ed25519_public_key).decode(),
        )
        for row in rows
    ]


def for_owner(db: Session, owner_id: uuid.UUID, journey_id: uuid.UUID) -> list[schemas.Helper]:
    """Helpers the traveller sees, one per person even if both alert levels were open."""
    seen: dict[uuid.UUID, schemas.Helper] = {}
    for helper, _ in _open_helpers(db, journey_id):
        if helper.account_id in seen:
            continue
        label, link_id = None, None
        if helper.kind == "contact":
            link_id = db.scalar(
                select(TrustedContact.id).where(
                    TrustedContact.owner_id == owner_id,
                    TrustedContact.contact_id == helper.account_id,
                )
            )
            if link_id is None:  # the Walk With Me companion, alerted by the SOS
                from app.profiles.models import Profile

                profile = db.get(Profile, helper.account_id)
                label = profile.first_name if profile else None
        else:
            label = db.scalar(
                select(ResponderProfile.display_name).where(
                    ResponderProfile.account_id == helper.account_id
                )
            )
        seen[helper.account_id] = schemas.Helper(
            id=helper.id,
            kind=helper.kind,
            label=label,
            contact_link_id=link_id,
            status=helper.status,
            accepted_at=helper.accepted_at,
            keys=device_keys(db, helper.account_id),
        )
    return list(seen.values())


def count_going(db: Session, escalation_id: uuid.UUID) -> int:
    return len(
        db.scalars(
            select(EscalationHelper.id).where(EscalationHelper.escalation_id == escalation_id)
        ).all()
    )


def status_of(db: Session, escalation_id: uuid.UUID, account_id: uuid.UUID) -> str | None:
    return db.scalar(
        select(EscalationHelper.status).where(
            EscalationHelper.escalation_id == escalation_id,
            EscalationHelper.account_id == account_id,
        )
    )


def is_helping(db: Session, escalation_id: uuid.UUID, account_id: uuid.UUID) -> bool:
    return (
        db.scalar(
            select(EscalationHelper.id).where(
                EscalationHelper.escalation_id == escalation_id,
                EscalationHelper.account_id == account_id,
            )
        )
        is not None
    )
