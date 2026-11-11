"""Journey jobs for the W4 watchdog: advance timers on quiet phones and drop old journeys."""

from dataclasses import dataclass
from datetime import datetime, timedelta

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.core import audit
from app.journey.models import Journey
from app.journey.state import ESCALATED_STATES, State, advance_by_time

RETENTION = timedelta(days=7)


@dataclass(frozen=True)
class Escalated:
    journey_id: str
    state: State


def advance(db: Session, journey: Journey, now: datetime) -> State | None:
    """Apply due timer transitions to one journey. Returns the new state if it escalated."""
    current = journey.to_state()
    before = current.state
    if not advance_by_time(current, journey.timers(), now):
        return None
    journey.load_state(current)
    audit.record(
        db, f"journey.{current.state}", actor=journey.account_id, target=f"journey:{journey.id}"
    )
    if current.state in ESCALATED_STATES and current.state != before:
        return current.state
    return None


def run_watchdog(db: Session, now: datetime) -> list[Escalated]:
    """Advance every unresolved journey. W4 schedules this and alerts contacts for the result."""
    escalated = []
    journeys = db.scalars(
        select(Journey)
        .where(Journey.state != State.RESOLVED.value)
        .with_for_update(skip_locked=True)
    )
    for journey in journeys:
        if (state := advance(db, journey, now)) is not None:
            escalated.append(Escalated(str(journey.id), state))
    db.commit()
    return escalated


def purge_expired(db: Session, now: datetime) -> int:
    """Delete journeys that ended more than 7 days ago (HLD §8 retention)."""
    result = db.execute(
        delete(Journey).where(
            Journey.state == State.RESOLVED.value, Journey.ended_at < now - RETENTION
        )
    )
    db.commit()
    return result.rowcount
