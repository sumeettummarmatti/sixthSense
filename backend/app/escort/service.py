"""Escort lookups shared by the router and the relay."""

import uuid
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.contacts.models import TrustedContact
from app.escort.models import AudioEscort
from app.journey.models import Journey
from app.journey.state import State


def running(db: Session, journey_id: uuid.UUID, now: datetime) -> AudioEscort | None:
    """The journey's running escort; one past its end time is closed as expired."""
    escort = db.scalars(
        select(AudioEscort).where(
            AudioEscort.journey_id == journey_id, AudioEscort.ended_at.is_(None)
        )
    ).first()
    if escort is None:
        return None
    journey = db.get(Journey, journey_id)
    if journey is None or journey.state == State.RESOLVED.value:
        escort.ended_at = now
        escort.end_reason = "journey_over"
    elif escort.ends_at <= now:
        escort.ended_at = escort.ends_at
        escort.end_reason = "expired"
    else:
        return escort
    db.flush()
    return None


def listener_accounts(db: Session, escort: AudioEscort) -> set[uuid.UUID]:
    return set(
        db.scalars(
            select(TrustedContact.contact_id).where(
                TrustedContact.id.in_(escort.listener_link_ids),
                TrustedContact.owner_id == escort.account_id,
                TrustedContact.contact_id.is_not(None),
            )
        )
    )
