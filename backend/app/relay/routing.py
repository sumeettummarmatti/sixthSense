"""Who may receive a location or audio envelope. The server reads only the plain routing fields
(session_id, sender_key_id, recipient_key_id); coordinates and audio stay encrypted end to end."""

import base64
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import cast

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.contacts.models import TrustedContact
from app.escalation import helpers
from app.escort import service as escort_service
from app.identity.models import Device, DeviceE2EKeys
from app.identity.router import CurrentSession
from app.journey.models import Journey
from app.journey.state import ESCALATED_STATES, State
from app.verification.eligibility import eligible
from app.walks import service as walks

ENVELOPE_FIELDS = frozenset(
    {
        "v",
        "session_id",
        "sender_key_id",
        "recipient_key_id",
        "ephemeral_public_key",
        "nonce",
        "ciphertext",
        "mac",
        "signature",
    }
)
MAX_ENVELOPES = 10
MAX_FIELD_LENGTH = 2048
# A 5 s voice clip is ~10 KB of AAC; base64 twice (inside and outside the cipher) ~18 KB.
MAX_AUDIO_CIPHERTEXT = 65536


class RelayError(ValueError):
    """Rejects the whole message; `str(error)` is the detail sent back to the phone."""


@dataclass
class Routed:
    deliveries: list[tuple[uuid.UUID, dict]] = field(default_factory=list)
    not_allowed: int = 0


def _validate(envelopes: object, max_ciphertext: int = MAX_FIELD_LENGTH) -> uuid.UUID:
    if not isinstance(envelopes, list) or not 1 <= len(envelopes) <= MAX_ENVELOPES:
        raise RelayError("bad_envelopes")
    session_ids = set()
    for envelope in envelopes:
        if not isinstance(envelope, dict) or set(envelope) != ENVELOPE_FIELDS:
            raise RelayError("bad_envelope")
        if envelope["v"] != 1:
            raise RelayError("unsupported_version")
        for name in ENVELOPE_FIELDS - {"v"}:
            value = envelope[name]
            limit = max_ciphertext if name == "ciphertext" else MAX_FIELD_LENGTH
            if not isinstance(value, str) or not 0 < len(value) <= limit:
                raise RelayError("bad_envelope")
        session_ids.add(envelope["session_id"])
    if len(session_ids) != 1:
        raise RelayError("mixed_sessions")
    try:
        return uuid.UUID(session_ids.pop())
    except ValueError as exc:
        raise RelayError("no_open_journey") from exc


def _traveller_recipients(db: Session, journey: Journey) -> set[uuid.UUID]:
    """Accepted contacts (or the protocol's alert list), plus responders who said "I'm going"
    to an open alert on this journey."""
    contacts = select(TrustedContact.contact_id).where(
        TrustedContact.owner_id == journey.account_id, TrustedContact.contact_id.is_not(None)
    )
    if journey.alert_contact_ids is not None:
        contacts = contacts.where(TrustedContact.id.in_(journey.alert_contact_ids))
    now = datetime.now(UTC)
    responders = {
        account
        for account in helpers.helper_accounts(db, journey.id, kind="responder")
        if eligible(db, account, "responder", now)
    }
    return set(db.scalars(contacts)) | responders


def _active_helpers(db: Session, journey_id: uuid.UUID) -> set[uuid.UUID]:
    """Contacts may help as trusted contacts; responders must remain eligible."""
    now = datetime.now(UTC)
    contacts = helpers.helper_accounts(db, journey_id, kind="contact")
    responders = {
        account
        for account in helpers.helper_accounts(db, journey_id, kind="responder")
        if eligible(db, account, "responder", now)
    }
    return contacts | responders


def route(db: Session, sender: CurrentSession, envelopes: object) -> Routed:
    """Check a location message (traveller, or a helper on their way) and route each envelope."""
    journey_id = _validate(envelopes)
    envelopes = cast(list[dict], envelopes)
    journey = db.get(Journey, journey_id)
    if journey is None:
        # Walk With Me: session id = walk id; the two walkers share with each other only.
        walk = walks.accepted_walk(db, journey_id)
        if walk is None or sender.account_id not in (walk.traveller_id, walk.companion_id):
            raise RelayError("no_open_journey")
        # A companion whose identity is revoked or expired mid-walk stops sending and receiving.
        if not eligible(db, walk.companion_id, "companion", datetime.now(UTC)):
            raise RelayError("no_open_journey")
        other = walk.companion_id if sender.account_id == walk.traveller_id else walk.traveller_id
        return _deliveries(db, sender, envelopes, {other}, "location")
    if journey.state == State.RESOLVED:
        raise RelayError("no_open_journey")
    if journey.account_id == sender.account_id:
        allowed_accounts = _traveller_recipients(db, journey)
    elif sender.account_id in _active_helpers(db, journey.id):
        # A helper on their way shares their own location with the traveller only.
        allowed_accounts = {journey.account_id}
    else:
        raise RelayError("no_open_journey")

    return _deliveries(db, sender, envelopes, allowed_accounts, "location")


def audio_recipients(db: Session, journey: Journey, now: datetime) -> set[uuid.UUID]:
    """Who may hear the traveller: everyone alerted during an alert (contacts and responders on
    their way), plus the listeners of a running audio escort. Nobody otherwise (rule 4)."""
    allowed: set[uuid.UUID] = set()
    if journey.state in {state.value for state in ESCALATED_STATES}:
        allowed |= _traveller_recipients(db, journey)
    escort = escort_service.running(db, journey.id, now)
    if escort is not None:
        allowed |= escort_service.listener_accounts(db, escort)
    return allowed


def route_audio(db: Session, sender: CurrentSession, envelopes: object, now: datetime) -> Routed:
    """Check an audio clip message from the traveller and route each envelope."""
    journey_id = _validate(envelopes, MAX_AUDIO_CIPHERTEXT)
    envelopes = cast(list[dict], envelopes)
    journey = db.get(Journey, journey_id)
    if (
        journey is None
        or journey.state == State.RESOLVED
        or journey.account_id != sender.account_id
    ):
        raise RelayError("no_open_journey")
    allowed = audio_recipients(db, journey, now)
    if not allowed:
        raise RelayError("not_listening")
    return _deliveries(db, sender, envelopes, allowed, "audio")


def may_still_hear(db: Session, journey_id: str, account_id: uuid.UUID, now: datetime) -> bool:
    """A clip queued for an offline listener is dropped once they may no longer hear it."""
    try:
        journey = db.get(Journey, uuid.UUID(journey_id))
    except ValueError:
        return False
    if journey is None or journey.state == State.RESOLVED:
        return False
    return account_id in audio_recipients(db, journey, now)


def _deliveries(
    db: Session,
    sender: CurrentSession,
    envelopes: list[dict],
    allowed_accounts: set[uuid.UUID],
    kind: str,
) -> Routed:
    sender_keys = db.get(DeviceE2EKeys, sender.device_id)
    if sender_keys is None or any(
        envelope["sender_key_id"] != str(sender_keys.key_id) for envelope in envelopes
    ):
        raise RelayError("stale_sender_key")

    wanted = set()
    for envelope in envelopes:
        try:
            wanted.add(uuid.UUID(envelope["recipient_key_id"]))
        except ValueError:
            continue
    recipients = {
        str(key_id): (device_id, account_id)
        for key_id, device_id, account_id in db.execute(
            select(DeviceE2EKeys.key_id, Device.id, Device.account_id)
            .join(Device, Device.id == DeviceE2EKeys.device_id)
            .where(DeviceE2EKeys.key_id.in_(wanted), Device.revoked_at.is_(None))
        )
    }

    sender_block = {
        "key_id": str(sender_keys.key_id),
        "ed25519_public_key": base64.b64encode(sender_keys.ed25519_public_key).decode(),
    }
    routed = Routed()
    for envelope in envelopes:
        target = recipients.get(envelope["recipient_key_id"])
        if target is None or target[1] not in allowed_accounts:
            routed.not_allowed += 1
            continue
        routed.deliveries.append(
            (target[0], {"type": kind, "envelope": envelope, "sender": sender_block})
        )
    return routed
