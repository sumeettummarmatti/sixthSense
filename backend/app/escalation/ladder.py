"""Escalation: open an alert when a journey escalates, walk each contact down the free channel
ladder until someone acknowledges, and close it when the journey calms down (P2-W4).

All contacts are alerted at once (parallel); each one moves push -> telegram -> email a minute
apart, skipping channels they haven't set up, then repeats every 5 minutes for about an hour.
The first acknowledgement stops the ladder for everyone. Idempotent: one escalation per
(journey, level), recipients locked while being processed.
"""

import logging
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.contacts.models import TrustedContact
from app.core import audit, crypto
from app.core.config import Settings
from app.escalation.models import Escalation, EscalationRecipient
from app.identity import security
from app.identity.models import Device
from app.journey.models import Journey
from app.journey.state import ESCALATED_STATES, Outcome, State
from app.notification import signing
from app.notification.channels import CHANNEL_ORDER, Message, Senders
from app.notification.models import AlertChannels

log = logging.getLogger(__name__)

RETENTION = timedelta(days=90)


def ack_token_hash(settings: Settings, token: str) -> bytes:
    return bytes.fromhex(security.keyed_hash(settings.token_secret, "escalation-ack", token))


# --- messages --------------------------------------------------------------------------------


def _wording(escalation: Escalation, label: str) -> tuple[str, str]:
    """Plain words, no location (the phone's own SMS carries that; live location is E2E)."""
    if escalation.covert:
        return (
            f"URGENT: {label} triggered a silent alarm",
            f"{label} may be in danger and may not be able to talk. Do NOT call their phone. "
            "Call 112 if you think they are at risk.",
        )
    if escalation.level == State.FULL_ESCALATION:
        return (
            f"URGENT: {label} may need help now",
            f"Try to reach {label} right away. If you can't, call 112.",
        )
    return (
        f"{label} missed a safety check-in",
        f"{label} hasn't checked in and didn't answer a private prompt. Please try to reach them.",
    )


def alert_message(
    escalation: Escalation,
    recipient: EscalationRecipient,
    ack_url: str,
    settings: Settings,
    now: datetime,
) -> Message:
    """The alert for one contact: signed for push, with a verification code for people."""
    title, body = _wording(escalation, recipient.owner_label)
    code = signing.verification_code(
        settings.token_secret, str(escalation.id), str(recipient.contact_account_id)
    )
    payload = {
        "v": 1,
        "type": "alert",
        "escalation_id": str(escalation.id),
        "level": escalation.level,
        "covert": escalation.covert,
        "owner_label": recipient.owner_label,
        "opened_at": escalation.opened_at.isoformat(),
        "issued_at": now.isoformat(),
        "code": code,
    }
    return Message(title, body, ack_url, code=code, data=signing.sign(payload, settings))


def all_clear_message(label: str, reason: str) -> Message:
    if reason == "resolved_by_contact":
        return Message("All clear", f"Another trusted contact confirmed {label} is safe.")
    return Message("All clear", f"{label} checked in and is OK.")


# --- opening and closing -------------------------------------------------------------------


def _recipients_for(db: Session, journey: Journey) -> list[TrustedContact]:
    query = select(TrustedContact).where(
        TrustedContact.owner_id == journey.account_id, TrustedContact.contact_id.is_not(None)
    )
    if journey.alert_contact_ids is not None:
        query = query.where(TrustedContact.id.in_(journey.alert_contact_ids))
    return list(db.scalars(query))


def _open(db: Session, journey: Journey, settings: Settings, now: datetime) -> None:
    escalation_id = db.scalar(
        insert(Escalation)
        .values(
            journey_id=journey.id,
            owner_id=journey.account_id,
            level=journey.state,
            covert=journey.covert,
            opened_at=now,
        )
        .on_conflict_do_nothing(
            index_elements=["journey_id", "level"], index_where=Escalation.closed_at.is_(None)
        )
        .returning(Escalation.id)
    )
    if escalation_id is None:  # already open: a duplicate trigger sends nothing extra
        return
    links = _recipients_for(db, journey)
    alerted = {link.contact_id for link in links}
    for link in links:
        token = security.new_token()
        db.add(
            EscalationRecipient(
                escalation_id=escalation_id,
                contact_account_id=link.contact_id,
                owner_label=link.owner_label,
                ack_token_hash=ack_token_hash(settings, token),
                ack_token_enc=crypto.encrypt(token),
                next_attempt_at=now,
            )
        )
    target = f"escalation:{escalation_id}"
    if journey.state == State.FULL_ESCALATION:
        _add_walk_companion(db, journey, escalation_id, alerted, settings, now)
    audit.record(db, f"escalation.opened.{journey.state}", actor=journey.account_id, target=target)
    if not links:
        audit.record(db, "escalation.no_contacts", actor=journey.account_id, target=target)
    log.info("escalation opened (%s, %d recipients)", journey.state, len(links))


def _add_walk_companion(
    db: Session,
    journey: Journey,
    escalation_id: uuid.UUID,
    alerted: set[uuid.UUID],
    settings: Settings,
    now: datetime,
) -> None:
    """An SOS during Walk With Me also alerts the companion walking with them."""
    from app.profiles.models import Profile  # local: keeps the ladder's imports small
    from app.walks import service as walks

    walk = walks.accepted_walk_for_journey(db, journey.id)
    if walk is None or walk.companion_id in alerted:
        return
    profile = db.get(Profile, journey.account_id)
    token = security.new_token()
    db.add(
        EscalationRecipient(
            escalation_id=escalation_id,
            contact_account_id=walk.companion_id,
            owner_label=profile.first_name if profile else "Your walk partner",
            ack_token_hash=ack_token_hash(settings, token),
            ack_token_enc=crypto.encrypt(token),
            next_attempt_at=now,
            kind="companion",
        )
    )
    audit.record(
        db, "escalation.walk_companion", actor=journey.account_id, target=f"walk:{walk.id}"
    )


@dataclass(frozen=True)
class Closed:
    escalation_id: uuid.UUID
    reason: str
    resolved_by: uuid.UUID | None = None  # the contact who said "they're safe" gets no all-clear


def close(
    db: Session,
    escalation: Escalation,
    reason: str,
    now: datetime,
    resolved_by: uuid.UUID | None = None,
) -> Closed:
    escalation.closed_at = now
    escalation.close_reason = reason
    audit.record(
        db,
        f"escalation.closed.{reason}",
        actor=escalation.owner_id,
        target=f"escalation:{escalation.id}",
    )
    return Closed(escalation.id, reason, resolved_by)


def sync(db: Session, settings: Settings, now: datetime) -> list[Closed]:
    """Open escalations for escalated journeys; close ones whose journey moved on."""
    escalated = db.scalars(
        select(Journey).where(Journey.state.in_([s.value for s in ESCALATED_STATES]))
    )
    for journey in escalated:
        _open(db, journey, settings, now)

    closed = []
    open_escalations = db.scalars(
        select(Escalation).where(Escalation.closed_at.is_(None)).with_for_update(skip_locked=True)
    )
    for escalation in open_escalations:
        journey = db.get(Journey, escalation.journey_id) if escalation.journey_id else None
        if journey is None:
            closed.append(close(db, escalation, "journey_ended", now))
        elif journey.state == escalation.level:
            continue
        elif journey.state == State.FULL_ESCALATION:
            closed.append(close(db, escalation, "superseded", now))
        elif journey.outcome == Outcome.RESOLVED_BY_CONTACT:
            closed.append(close(db, escalation, "resolved_by_contact", now))
        elif journey.state == State.RESOLVED:
            closed.append(close(db, escalation, "journey_ended", now))
        else:
            closed.append(close(db, escalation, "owner_checked_in", now))
    db.commit()
    return closed


# --- sending -------------------------------------------------------------------------------


def _targets(db: Session, channel: str, contact_id: uuid.UUID) -> list[str]:
    if channel == "push":
        tokens = db.scalars(
            select(Device.fcm_token_enc).where(
                Device.account_id == contact_id,
                Device.revoked_at.is_(None),
                Device.fcm_token_enc.is_not(None),
            )
        )
        return [t for t in (crypto.decrypt(token) for token in tokens) if t]
    channels = db.get(AlertChannels, contact_id)
    if channels is None:
        return []
    value = crypto.decrypt(
        channels.telegram_chat_id_enc if channel == "telegram" else channels.email_enc
    )
    return [value] if value else []


def _deliver(db: Session, senders: Senders, channel: str, contact_id, message: Message) -> bool:
    sender = senders.by_name(channel)
    if not sender.configured():
        return False
    results = [sender.send(target, message) for target in _targets(db, channel, contact_id)]
    return any(results)


def send_due(db: Session, senders: Senders, settings: Settings, now: datetime) -> int:
    """Send the next ladder step to every recipient that is due. Returns messages sent."""
    rows = db.execute(
        select(EscalationRecipient, Escalation)
        .join(Escalation, Escalation.id == EscalationRecipient.escalation_id)
        .where(
            Escalation.closed_at.is_(None),
            Escalation.acknowledged_at.is_(None),
            EscalationRecipient.next_attempt_at <= now,
        )
        .with_for_update(of=EscalationRecipient, skip_locked=True)
    ).all()
    sent = 0
    for recipient, escalation in rows:
        token = crypto.decrypt(recipient.ack_token_enc) or ""
        message = alert_message(
            escalation,
            recipient,
            f"{settings.public_base_url}/escalations/ack#{token}",
            settings,
            now,
        )
        delivered = None
        # Never wait on one channel: skip channels that aren't set up or fail, right away.
        for index in range(recipient.step, len(CHANNEL_ORDER)):
            channel = CHANNEL_ORDER[index]
            if _deliver(db, senders, channel, recipient.contact_account_id, message):
                delivered, recipient.step = channel, index + 1
                break
        target = f"escalation:{escalation.id}"
        if delivered:
            sent += 1
            recipient.last_channel = delivered
            recipient.next_attempt_at = now + timedelta(seconds=settings.ladder_step_seconds)
            audit.record(
                db, f"escalation.sent.{delivered}", actor=escalation.owner_id, target=target
            )
            continue
        if recipient.cycle == 0 and recipient.last_channel is None:
            audit.record(db, "escalation.unreachable", actor=escalation.owner_id, target=target)
        recipient.step = 0
        recipient.cycle += 1
        recipient.next_attempt_at = (
            now + timedelta(seconds=settings.ladder_cycle_seconds)
            if recipient.cycle < settings.ladder_max_cycles
            else None
        )
    db.commit()
    return sent


def send_all_clear(db: Session, senders: Senders, closed: list[Closed]) -> None:
    """Tell contacts who were alerted that it's over, on the channel that reached them."""
    for item in closed:
        if item.reason not in ("owner_checked_in", "resolved_by_contact"):
            continue
        recipients = db.scalars(
            select(EscalationRecipient).where(
                EscalationRecipient.escalation_id == item.escalation_id,
                EscalationRecipient.last_channel.is_not(None),
            )
        )
        for recipient in recipients:
            if recipient.contact_account_id == item.resolved_by:
                continue  # they resolved it; telling them "another contact" did is wrong
            message = all_clear_message(recipient.owner_label, item.reason)
            _deliver(db, senders, recipient.last_channel, recipient.contact_account_id, message)


# --- acknowledging and retention -----------------------------------------------------------


def acknowledge(
    db: Session,
    escalation: Escalation,
    contact_id: uuid.UUID,
    now: datetime,
    kind: str = "contact",
) -> None:
    """Stop the ladder. For a missed check-in this also pauses the automatic upgrade to a full
    escalation: the contact now resolves it or raises the alarm. A walk companion is added as
    someone coming, but never stops the alerts to trusted contacts."""
    if kind == "companion":
        from app.escalation import helpers  # local: helpers imports matching models

        helpers.add(db, escalation, contact_id, "contact", now)
        return
    if escalation.level == State.CONTACT_ALERT and escalation.journey_id:
        journey = db.get(Journey, escalation.journey_id)
        if journey is not None and journey.state == State.CONTACT_ALERT:
            journey.alert_acknowledged_at = journey.alert_acknowledged_at or now
    from app.escalation import helpers  # local: helpers imports matching models

    helpers.add(db, escalation, contact_id, "contact", now)
    if escalation.acknowledged_at is None:
        escalation.acknowledged_at = now
        escalation.acknowledged_by = contact_id
        audit.record(
            db, "escalation.acknowledged", actor=contact_id, target=f"escalation:{escalation.id}"
        )


def purge_expired(db: Session, now: datetime) -> int:
    """Delete escalations older than 90 days (HLD §8)."""
    old = db.scalars(select(Escalation).where(Escalation.opened_at < now - RETENTION))
    count = 0
    for escalation in old:
        db.delete(escalation)
        count += 1
    db.commit()
    return count
