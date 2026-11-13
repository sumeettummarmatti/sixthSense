"""Audio Escort (P1-W3-audio-escort): start, stop with PIN, listen, and contact requests.

Consent rules: only the owner's phone can start one (a contact can only ask); the owner picks the
listeners and the length (≤ 3 h); the phone shows a notification the whole time. Stopping takes
the owner's PIN. The duress PIN gets the same answer but also starts a covert SOS, so whoever is
forcing the owner sees the escort end while contacts are alerted (and keep hearing them).
"""

import uuid
from datetime import UTC, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select

from app.contacts.models import TrustedContact
from app.core import audit
from app.escort import schemas, service
from app.escort.models import AudioEscort, EscortRequest
from app.identity.router import CurrentSessionDep, DbDep
from app.journey import service as journey_service
from app.journey.models import Journey
from app.journey.state import Event, InvalidTransition, State, apply_event
from app.notification.channels import Message, Senders, get_senders

router = APIRouter(prefix="/escorts", tags=["escort"])

REQUEST_TTL = timedelta(minutes=10)
SendersDep = Annotated[Senders, Depends(get_senders)]


def _now() -> datetime:
    return datetime.now(UTC)


NowDep = Annotated[datetime, Depends(_now)]


def _notify(db, senders: Senders, account: uuid.UUID, message: Message) -> None:
    from app.escalation.ladder import _deliver

    for channel in ("push", "telegram"):
        if _deliver(db, senders, channel, account, message):
            return


def _view(escort: AudioEscort) -> schemas.EscortView:
    return schemas.EscortView(
        id=escort.id,
        journey_id=escort.journey_id,
        started_at=escort.started_at,
        ends_at=escort.ends_at,
        listener_link_ids=escort.listener_link_ids,
    )


@router.post("", status_code=status.HTTP_201_CREATED, response_model=schemas.EscortView)
def start(
    body: schemas.EscortStart,
    session: CurrentSessionDep,
    db: DbDep,
    senders: SendersDep,
    now: NowDep,
) -> schemas.EscortView:
    journey = db.scalars(
        select(Journey)
        .where(Journey.id == body.journey_id, Journey.account_id == session.account_id)
        .with_for_update()
    ).first()
    if journey is None or journey.state == State.RESOLVED.value:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no_open_journey")
    wanted = set(body.contact_link_ids)
    links = db.scalars(
        select(TrustedContact).where(
            TrustedContact.owner_id == session.account_id,
            TrustedContact.contact_id.is_not(None),
            TrustedContact.id.in_(wanted),
        )
    ).all()
    if {link.id for link in links} != wanted:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "unknown_contact")
    if service.running(db, journey.id, now) is not None:
        raise HTTPException(status.HTTP_409_CONFLICT, "escort_already_on")
    escort = AudioEscort(
        journey_id=journey.id,
        account_id=session.account_id,
        listener_link_ids=sorted(wanted),
        started_at=now,
        ends_at=now + timedelta(minutes=body.minutes),
    )
    db.add(escort)
    if body.request_id is not None:
        request = db.get(EscortRequest, body.request_id)
        if request is not None and request.owner_id == session.account_id:
            request.status = "accepted"
            request.responded_at = now
    db.flush()
    audit.record(db, "escort.started", actor=session.account_id, target=f"escort:{escort.id}")
    for link in links:
        _notify(
            db,
            senders,
            link.contact_id,
            Message(
                title=f"{link.owner_label} started an audio escort",
                body="You can listen live in the SixthSense app until it ends.",
            ),
        )
    db.commit()
    return _view(escort)


@router.get("/current", response_model=schemas.EscortView)
def current(session: CurrentSessionDep, db: DbDep, now: NowDep) -> schemas.EscortView:
    escort = db.scalars(
        select(AudioEscort).where(
            AudioEscort.account_id == session.account_id, AudioEscort.ended_at.is_(None)
        )
    ).first()
    if escort is not None:
        escort = service.running(db, escort.journey_id, now)
    db.commit()
    if escort is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no_escort")
    return _view(escort)


@router.post("/{escort_id}/stop", response_model=schemas.Stopped)
def stop(
    escort_id: uuid.UUID,
    body: schemas.EscortStop,
    session: CurrentSessionDep,
    db: DbDep,
    now: NowDep,
) -> schemas.Stopped:
    escort = db.get(AudioEscort, escort_id)
    if escort is None or escort.account_id != session.account_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no_escort")
    if escort.ended_at is None:
        escort.ended_at = now
        escort.end_reason = "duress" if body.result == "duress" else "stopped"
    if body.result == "duress":
        journey = db.scalars(
            select(Journey).where(Journey.id == escort.journey_id).with_for_update()
        ).first()
        if journey is not None:
            journey_service.advance(db, journey, now)
            current_state = journey.to_state()
            try:
                apply_event(current_state, Event.COVERT_SOS, journey.timers(), now)
                journey.load_state(current_state)
                audit.record(
                    db,
                    "journey.covert_sos",
                    actor=session.account_id,
                    target=f"journey:{journey.id}",
                )
            except InvalidTransition:
                pass  # already escalated or over: contacts are alerted already
    audit.record(db, "escort.stopped", actor=session.account_id, target=f"escort:{escort.id}")
    db.commit()
    return schemas.Stopped()


@router.get("/listening", response_model=schemas.ListeningList)
def listening(session: CurrentSessionDep, db: DbDep, now: NowDep) -> schemas.ListeningList:
    """Escorts I'm a listener on, while they run (rule 4: nothing before or after)."""
    rows = db.execute(
        select(AudioEscort, TrustedContact)
        .join(TrustedContact, TrustedContact.id == AudioEscort.listener_link_ids.any_())
        .join(Journey, Journey.id == AudioEscort.journey_id)
        .where(
            Journey.state != State.RESOLVED.value,
            AudioEscort.ended_at.is_(None),
            AudioEscort.ends_at > now,
            TrustedContact.contact_id == session.account_id,
            TrustedContact.owner_id == AudioEscort.account_id,
        )
    ).all()
    return schemas.ListeningList(
        escorts=[
            schemas.Listening(
                escort_id=escort.id,
                journey_id=escort.journey_id,
                contact_link_id=link.id,
                owner_label=link.owner_label,
                ends_at=escort.ends_at,
            )
            for escort, link in rows
        ]
    )


@router.get("/supporting", response_model=schemas.SupportedList)
def supporting(session: CurrentSessionDep, db: DbDep) -> schemas.SupportedList:
    """People who made me their trusted contact, so I can ask one of them for an escort."""
    links = db.scalars(
        select(TrustedContact)
        .where(TrustedContact.contact_id == session.account_id)
        .order_by(TrustedContact.accepted_at)
    ).all()
    return schemas.SupportedList(
        people=[
            schemas.Supported(contact_link_id=link.id, owner_label=link.owner_label)
            for link in links
        ]
    )


@router.post("/requests", status_code=status.HTTP_201_CREATED, response_model=schemas.RequestView)
def ask(
    body: schemas.RequestCreate,
    session: CurrentSessionDep,
    db: DbDep,
    senders: SendersDep,
    now: NowDep,
) -> schemas.RequestView:
    """A contact asks the owner for an escort. Only the owner's phone can start one."""
    link = db.get(TrustedContact, body.contact_link_id)
    if link is None or link.contact_id != session.account_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "contact_not_found")
    existing = db.scalars(
        select(EscortRequest).where(
            EscortRequest.link_id == link.id,
            EscortRequest.status == "pending",
            EscortRequest.created_at > now - REQUEST_TTL,
        )
    ).first()
    if existing is None:
        existing = EscortRequest(
            link_id=link.id, owner_id=link.owner_id, requester_id=session.account_id, created_at=now
        )
        db.add(existing)
        db.flush()
        audit.record(
            db, "escort.requested", actor=session.account_id, target=f"escort_request:{existing.id}"
        )
        _notify(
            db,
            senders,
            link.owner_id,
            Message(
                title="A contact asks to keep you company",
                body="Open SixthSense to start an audio escort or say no. Only you can start one.",
            ),
        )
    db.commit()
    return schemas.RequestView(
        id=existing.id, contact_link_id=link.id, created_at=existing.created_at
    )


@router.get("/requests", response_model=schemas.RequestList)
def requests(session: CurrentSessionDep, db: DbDep, now: NowDep) -> schemas.RequestList:
    rows = db.scalars(
        select(EscortRequest)
        .where(
            EscortRequest.owner_id == session.account_id,
            EscortRequest.status == "pending",
            EscortRequest.created_at > now - REQUEST_TTL,
        )
        .order_by(EscortRequest.created_at)
    ).all()
    return schemas.RequestList(
        requests=[
            schemas.RequestView(id=r.id, contact_link_id=r.link_id, created_at=r.created_at)
            for r in rows
        ]
    )


@router.post("/requests/{request_id}/decline", response_model=schemas.Stopped)
def decline(
    request_id: uuid.UUID, session: CurrentSessionDep, db: DbDep, now: NowDep
) -> schemas.Stopped:
    request = db.get(EscortRequest, request_id)
    if request is None or request.owner_id != session.account_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "request_not_found")
    if request.status == "pending":
        request.status = "declined"
        request.responded_at = now
    db.commit()
    return schemas.Stopped()
