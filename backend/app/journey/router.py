"""Journeys (P2-W3): protocol settings, start, heartbeat, check-in, prompt, SOS, arrive, end.

The phone runs the timers and checks the PIN locally; it reports what happened here. Every
read or event first applies any timer transitions the server has seen pass (the same step the
W4 watchdog runs), so the server and phone stay in step. No location is ever sent here: live
location goes end-to-end encrypted through the relay (P2-W5).
"""

import logging
import uuid
from datetime import UTC, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select

from app.contacts.models import TrustedContact
from app.core import audit
from app.identity.router import CurrentSessionDep, DbDep
from app.journey import schemas, service
from app.journey.models import Journey, Protocol
from app.journey.state import Event, InvalidTransition, State, apply_event, public_state

router = APIRouter(prefix="/journeys", tags=["journey"])
log = logging.getLogger(__name__)

_NO_JOURNEY = HTTPException(status.HTTP_404_NOT_FOUND, "no_open_journey")
_NOT_FOUND = HTTPException(status.HTTP_404_NOT_FOUND, "journey_not_found")

_SETTINGS_FIELDS = tuple(schemas.ProtocolSettings.model_fields)


def _now() -> datetime:
    return datetime.now(UTC)


NowDep = Annotated[datetime, Depends(_now)]


def _settings_of(row: Protocol | Journey | None) -> schemas.ProtocolSettings:
    if row is None:
        return schemas.ProtocolSettings()
    return schemas.ProtocolSettings(**{name: getattr(row, name) for name in _SETTINGS_FIELDS})


def _view(journey: Journey) -> schemas.JourneyView:
    current = journey.to_state()
    return schemas.JourneyView(
        id=journey.id,
        state=public_state(current).value,
        outcome=journey.outcome if public_state(current) == State.RESOLVED else None,
        started_at=journey.started_at,
        next_check_in_at=journey.next_check_in_at,
        timers=_settings_of(journey),
    )


def _visible_open_journey(db: DbDep, account_id: uuid.UUID) -> Journey | None:
    """The journey the owner's phone should see as open (a covert one counts until 'ended')."""
    return db.scalars(
        select(Journey)
        .where(
            Journey.account_id == account_id,
            Journey.state != State.RESOLVED.value,
            Journey.cover_ended_at.is_(None),
        )
        .order_by(Journey.started_at.desc())
        .with_for_update()
    ).first()


# --- protocol -------------------------------------------------------------------------------


@router.get("/protocol", response_model=schemas.ProtocolSettings)
def get_protocol(session: CurrentSessionDep, db: DbDep) -> schemas.ProtocolSettings:
    return _settings_of(db.get(Protocol, session.account_id))


@router.put("/protocol", response_model=schemas.ProtocolSettings)
def put_protocol(
    body: schemas.ProtocolSettings, session: CurrentSessionDep, db: DbDep, now: NowDep
) -> schemas.ProtocolSettings:
    if body.alert_contact_ids is not None:
        wanted = set(body.alert_contact_ids)
        accepted = set(
            db.scalars(
                select(TrustedContact.id).where(
                    TrustedContact.owner_id == session.account_id,
                    TrustedContact.contact_id.is_not(None),
                    TrustedContact.id.in_(wanted),
                )
            )
        )
        if accepted != wanted:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "unknown_contact")
    protocol = db.get(Protocol, session.account_id) or Protocol(account_id=session.account_id)
    for name in _SETTINGS_FIELDS:
        setattr(protocol, name, getattr(body, name))
    protocol.updated_at = now
    db.add(protocol)
    audit.record(db, "protocol.updated", actor=session.account_id)
    db.commit()
    return _settings_of(protocol)


# --- journeys -------------------------------------------------------------------------------


@router.post("", status_code=status.HTTP_201_CREATED, response_model=schemas.JourneyView)
def start_journey(
    body: schemas.JourneyStart, session: CurrentSessionDep, db: DbDep, now: NowDep
) -> schemas.JourneyView:
    """Start a journey with a copy of the current protocol. One open journey at a time."""
    if _visible_open_journey(db, session.account_id) is not None:
        raise HTTPException(status.HTTP_409_CONFLICT, "journey_already_open")
    settings = _settings_of(db.get(Protocol, session.account_id))
    if body.check_in_interval_min is not None:
        settings.check_in_interval_min = body.check_in_interval_min
    journey = Journey(
        account_id=session.account_id,
        state=State.ACTIVE.value,
        covert=False,
        started_at=now,
        next_check_in_at=now + timedelta(minutes=settings.check_in_interval_min),
        last_heartbeat_at=now,
        state_changed_at=now,
        **settings.model_dump(),
    )
    db.add(journey)
    db.flush()
    audit.record(db, "journey.started", actor=session.account_id, target=f"journey:{journey.id}")
    db.commit()
    return _view(journey)


@router.get("/current", response_model=schemas.JourneyView)
def current_journey(session: CurrentSessionDep, db: DbDep, now: NowDep) -> schemas.JourneyView:
    journey = _visible_open_journey(db, session.account_id)
    if journey is None:
        raise _NO_JOURNEY
    service.advance(db, journey, now)
    db.commit()
    return _view(journey)


def _owned_journey(db: DbDep, account_id: uuid.UUID, journey_id: uuid.UUID) -> Journey:
    journey = db.scalars(
        select(Journey)
        .where(Journey.id == journey_id, Journey.account_id == account_id)
        .with_for_update()
    ).first()
    if journey is None:
        raise _NOT_FOUND
    return journey


def _apply(
    db: DbDep, account_id: uuid.UUID, journey_id: uuid.UUID, event: Event, now: datetime
) -> schemas.JourneyView:
    journey = _owned_journey(db, account_id, journey_id)
    service.advance(db, journey, now)
    current = journey.to_state()
    try:
        apply_event(current, event, journey.timers(), now)
    except InvalidTransition as exc:
        db.commit()  # keep any timer transitions applied above
        detail = "journey_over" if public_state(current) == State.RESOLVED else "invalid_for_state"
        raise HTTPException(status.HTTP_409_CONFLICT, detail) from exc
    journey.load_state(current)
    # Audit names are internal (never shown to the phone), so record what really happened.
    audit.record(db, f"journey.{event}", actor=account_id, target=f"journey:{journey.id}")
    db.commit()
    return _view(journey)


@router.post("/{journey_id}/heartbeat", response_model=schemas.JourneyView)
def heartbeat(
    journey_id: uuid.UUID, session: CurrentSessionDep, db: DbDep, now: NowDep
) -> schemas.JourneyView:
    """'Still here' from the phone. Carries no location."""
    journey = _owned_journey(db, session.account_id, journey_id)
    service.advance(db, journey, now)
    if public_state(journey.to_state()) == State.RESOLVED:
        db.commit()
        raise HTTPException(status.HTTP_409_CONFLICT, "journey_over")
    journey.last_heartbeat_at = now
    db.commit()
    return _view(journey)


@router.post("/{journey_id}/check-in", response_model=schemas.JourneyView)
def check_in(
    journey_id: uuid.UUID,
    body: schemas.CheckIn,
    session: CurrentSessionDep,
    db: DbDep,
    now: NowDep,
) -> schemas.JourneyView:
    """Real or duress PIN accepted on the phone. Both get exactly the same response."""
    event = Event.CHECK_IN_OK if body.result == "ok" else Event.CHECK_IN_DURESS
    return _apply(db, session.account_id, journey_id, event, now)


@router.post("/{journey_id}/prompt", response_model=schemas.JourneyView)
def prompt_shown(
    journey_id: uuid.UUID, session: CurrentSessionDep, db: DbDep, now: NowDep
) -> schemas.JourneyView:
    """The phone missed a check-in and is now showing the private PIN prompt."""
    return _apply(db, session.account_id, journey_id, Event.PROMPT_SHOWN, now)


@router.post("/{journey_id}/sos", response_model=schemas.JourneyView)
def sos(
    journey_id: uuid.UUID, body: schemas.Sos, session: CurrentSessionDep, db: DbDep, now: NowDep
) -> schemas.JourneyView:
    """Full escalation now. A covert SOS keeps showing the journey as normal."""
    event = Event.COVERT_SOS if body.covert else Event.SOS
    return _apply(db, session.account_id, journey_id, event, now)


@router.post("/{journey_id}/arrive", response_model=schemas.JourneyView)
def arrive(
    journey_id: uuid.UUID, session: CurrentSessionDep, db: DbDep, now: NowDep
) -> schemas.JourneyView:
    return _apply(db, session.account_id, journey_id, Event.ARRIVE, now)


@router.post("/{journey_id}/end", response_model=schemas.JourneyView)
def end(
    journey_id: uuid.UUID, session: CurrentSessionDep, db: DbDep, now: NowDep
) -> schemas.JourneyView:
    return _apply(db, session.account_id, journey_id, Event.END, now)
