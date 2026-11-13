"""Responder side (P3-W1): apply, go on duty, see nearby requests, say "I'm going".

A responder sees a request only while the alert is open and only if they were asked (rule 4).
Before "I'm going" they see a rough area and distance; after it, the traveller's phone adds them
to its end-to-end encrypted live location, and they share theirs back to the traveller.
"""

import uuid
from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import select

from app.core import audit
from app.core.redis import get_redis
from app.escalation import helpers
from app.escalation.models import Escalation
from app.identity.router import CurrentSessionDep, DbDep, SettingsDep
from app.matching import nearby, schemas
from app.matching.models import ResponderOffer, ResponderProfile

router = APIRouter(prefix="/responders", tags=["matching"])

RedisDep = Annotated[object, Depends(get_redis)]
_NOT_FOUND = HTTPException(status.HTTP_404_NOT_FOUND, "offer_not_found")


def _now() -> datetime:
    return datetime.now(UTC)


NowDep = Annotated[datetime, Depends(_now)]


@router.post("/apply", response_model=schemas.Me)
def apply(
    body: schemas.Apply, session: CurrentSessionDep, db: DbDep, settings: SettingsDep, now: NowDep
) -> schemas.Me:
    profile = db.get(ResponderProfile, session.account_id)
    if profile is None:
        profile = ResponderProfile(account_id=session.account_id, applied_at=now)
        db.add(profile)
    if profile.status == "revoked":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "responder_revoked")
    profile.display_name = body.display_name
    if settings.responder_auto_approve and profile.status != "approved":
        profile.status, profile.approved_at = "approved", now
    elif profile.status is None:
        profile.status = "pending"
    audit.record(db, "responder.applied", actor=session.account_id)
    db.commit()
    return schemas.Me(status=profile.status, display_name=profile.display_name)


@router.get("/me", response_model=schemas.Me)
def me(
    session: CurrentSessionDep, db: DbDep, redis: RedisDep, settings: SettingsDep, now: NowDep
) -> schemas.Me:
    profile = db.get(ResponderProfile, session.account_id)
    if profile is None:
        return schemas.Me(status="none")
    duty = nearby.presence_of(redis, session.account_id, settings, now) is not None
    return schemas.Me(status=profile.status, display_name=profile.display_name, on_duty=duty)


def _approved(db: DbDep, account_id: uuid.UUID) -> ResponderProfile:
    profile = db.get(ResponderProfile, account_id)
    if profile is None or profile.status != "approved":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "not_an_approved_responder")
    return profile


@router.put("/presence", response_model=schemas.OnDuty)
def put_presence(
    body: schemas.Presence,
    session: CurrentSessionDep,
    db: DbDep,
    redis: RedisDep,
    settings: SettingsDep,
    now: NowDep,
) -> schemas.OnDuty:
    """On duty: refresh about once a minute. Stops counting 5 minutes after the last refresh."""
    _approved(db, session.account_id)
    nearby.set_presence(redis, session.account_id, nearby.rough(body.latitude, body.longitude), now)
    return schemas.OnDuty(on_duty=True, expires_in_seconds=settings.responder_presence_ttl_seconds)


@router.delete("/presence", status_code=status.HTTP_204_NO_CONTENT)
def off_duty(session: CurrentSessionDep, redis: RedisDep) -> Response:
    nearby.clear_presence(redis, session.account_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


def _open_offers(db: DbDep, account_id: uuid.UUID):
    return db.execute(
        select(ResponderOffer, Escalation)
        .join(Escalation, Escalation.id == ResponderOffer.escalation_id)
        .where(
            ResponderOffer.responder_id == account_id,
            ResponderOffer.status != "declined",
            Escalation.closed_at.is_(None),
        )
        .order_by(ResponderOffer.offered_at)
    ).all()


@router.get("/offers", response_model=schemas.Offers)
def offers(
    session: CurrentSessionDep, db: DbDep, redis: RedisDep, settings: SettingsDep, now: NowDep
) -> schemas.Offers:
    """Open requests I was asked to help with. Empty for people who are not responders."""
    mine = nearby.presence_of(redis, session.account_id, settings, now)
    result = []
    for offer, escalation in _open_offers(db, session.account_id):
        area = nearby.alert_area(redis, escalation.journey_id)
        meters = nearby.distance_m(area, mine) if area and mine else offer.distance_m
        result.append(
            schemas.Offer(
                id=offer.id,
                journey_id=escalation.journey_id if offer.status == "going" else None,
                status=offer.status,
                distance_m=meters,
                walk_minutes=nearby.walk_minutes(meters),
                rough_area=schemas.Area(latitude=area.latitude, longitude=area.longitude)
                if area
                else None,
                covert=escalation.covert,
                opened_at=escalation.opened_at,
                helpers_going=helpers.count_going(db, escalation.id),
                arrived=helpers.status_of(db, escalation.id, session.account_id) == "arrived",
            )
        )
    return schemas.Offers(offers=result)


def _my_open_offer(db: DbDep, account_id: uuid.UUID, offer_id: uuid.UUID):
    row = db.execute(
        select(ResponderOffer, Escalation)
        .join(Escalation, Escalation.id == ResponderOffer.escalation_id)
        .where(
            ResponderOffer.id == offer_id,
            ResponderOffer.responder_id == account_id,
            Escalation.closed_at.is_(None),
        )
        .with_for_update(of=Escalation)
    ).first()
    if row is None:
        raise _NOT_FOUND
    return row[0], row[1]


@router.post("/offers/{offer_id}/going", response_model=schemas.OwnerKeys)
def going(
    offer_id: uuid.UUID, session: CurrentSessionDep, db: DbDep, settings: SettingsDep, now: NowDep
) -> schemas.OwnerKeys:
    """'I'm going.' The first few get the traveller's precise live location (E2E)."""
    _approved(db, session.account_id)
    offer, escalation = _my_open_offer(db, session.account_id, offer_id)
    if offer.status != "going":
        if nearby.going_count(db, escalation.id) >= settings.responder_precise_limit:
            raise HTTPException(status.HTTP_409_CONFLICT, "enough_helpers")
        offer.status, offer.responded_at = "going", now
        helpers.add(db, escalation, session.account_id, "responder", now)
        audit.record(db, "responder.going", actor=session.account_id, target=f"offer:{offer.id}")
        db.commit()
    if escalation.journey_id is None:
        raise _NOT_FOUND
    return schemas.OwnerKeys(
        journey_id=escalation.journey_id, keys=helpers.device_keys(db, escalation.owner_id)
    )


@router.post("/offers/{offer_id}/decline", status_code=status.HTTP_204_NO_CONTENT)
def decline(offer_id: uuid.UUID, session: CurrentSessionDep, db: DbDep, now: NowDep) -> Response:
    offer, _ = _my_open_offer(db, session.account_id, offer_id)
    if offer.status == "offered":
        offer.status, offer.responded_at = "declined", now
        audit.record(db, "responder.declined", actor=session.account_id, target=f"offer:{offer.id}")
        db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/offers/{offer_id}/arrived", status_code=status.HTTP_204_NO_CONTENT)
def arrived(offer_id: uuid.UUID, session: CurrentSessionDep, db: DbDep, now: NowDep) -> Response:
    offer, escalation = _my_open_offer(db, session.account_id, offer_id)
    if offer.status != "going" or not helpers.mark_arrived(
        db, escalation.id, session.account_id, now
    ):
        raise HTTPException(status.HTTP_409_CONFLICT, "not_going")
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
