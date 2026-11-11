"""Who may receive a location envelope. The server reads only the plain routing fields
(session_id, sender_key_id, recipient_key_id); coordinates stay encrypted end to end."""

import base64
import uuid
from dataclasses import dataclass, field
from typing import cast

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.contacts.models import TrustedContact
from app.identity.models import Device, DeviceE2EKeys
from app.identity.router import CurrentSession
from app.journey.models import Journey
from app.journey.state import State

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


class RelayError(ValueError):
    """Rejects the whole message; `str(error)` is the detail sent back to the phone."""


@dataclass
class Routed:
    deliveries: list[tuple[uuid.UUID, dict]] = field(default_factory=list)
    not_allowed: int = 0


def _validate(envelopes: object) -> uuid.UUID:
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
            if not isinstance(value, str) or not 0 < len(value) <= MAX_FIELD_LENGTH:
                raise RelayError("bad_envelope")
        session_ids.add(envelope["session_id"])
    if len(session_ids) != 1:
        raise RelayError("mixed_sessions")
    try:
        return uuid.UUID(session_ids.pop())
    except ValueError as exc:
        raise RelayError("no_open_journey") from exc


def route(db: Session, sender: CurrentSession, envelopes: object) -> Routed:
    """Check a location message from the traveller and work out where each envelope goes."""
    journey_id = _validate(envelopes)
    envelopes = cast(list[dict], envelopes)
    journey = db.get(Journey, journey_id)
    if journey is None or journey.account_id != sender.account_id:
        raise RelayError("no_open_journey")
    if journey.state == State.RESOLVED:
        raise RelayError("no_open_journey")

    sender_keys = db.get(DeviceE2EKeys, sender.device_id)
    if sender_keys is None or any(
        envelope["sender_key_id"] != str(sender_keys.key_id) for envelope in envelopes
    ):
        raise RelayError("stale_sender_key")

    contacts = select(TrustedContact.contact_id).where(
        TrustedContact.owner_id == sender.account_id, TrustedContact.contact_id.is_not(None)
    )
    if journey.alert_contact_ids is not None:
        contacts = contacts.where(TrustedContact.id.in_(journey.alert_contact_ids))
    allowed_accounts = set(db.scalars(contacts))

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
            (target[0], {"type": "location", "envelope": envelope, "sender": sender_block})
        )
    return routed
