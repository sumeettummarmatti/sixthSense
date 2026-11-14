"""POST /feedback: the journey's owner says how it went. Stored raw; nothing is computed."""

import uuid
from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select

from app.core import audit
from app.escalation.models import Escalation
from app.feedback import schemas
from app.feedback.models import Feedback
from app.identity.router import CurrentSessionDep, DbDep, RedisDep
from app.journey.models import Journey
from app.matching.models import ResponderOffer, ResponderProfile
from app.moderation import service as moderation
from app.moderation.models import ResponderRating

router = APIRouter(prefix="/feedback", tags=["feedback"])


def _now() -> datetime:
    return datetime.now(UTC)


NowDep = Annotated[datetime, Depends(_now)]


@router.post("", response_model=schemas.FeedbackOut, status_code=status.HTTP_201_CREATED)
def give_feedback(
    body: schemas.FeedbackIn, session: CurrentSessionDep, db: DbDep, redis: RedisDep, now: NowDep
) -> schemas.FeedbackOut:
    from app.walks.models import Walk  # walks imports feedback for ratings

    journey = db.get(Journey, body.journey_id)
    if journey is None or journey.account_id != session.account_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "journey_not_found")
    walk = None
    if body.walk_id is not None:
        walk = db.get(Walk, body.walk_id)
        if walk is None or walk.journey_id != journey.id or walk.status != "ended":
            raise HTTPException(status.HTTP_404_NOT_FOUND, "walk_not_found")
    duplicate = db.scalar(
        select(Feedback.id).where(
            Feedback.journey_id == journey.id,
            Feedback.walk_id.is_(None)
            if body.walk_id is None
            else Feedback.walk_id == body.walk_id,
        )
    )
    if duplicate is not None:
        raise HTTPException(status.HTTP_409_CONFLICT, "feedback_already_given")
    item = Feedback(
        journey_id=journey.id,
        walk_id=body.walk_id,
        route_stars=body.route_stars,
        companion_stars=body.companion_stars,
        chips=list(dict.fromkeys(body.chips)),
        note=body.note,
        created_at=now,
    )
    db.add(item)
    db.flush()
    audit.record(db, "feedback.created", actor=session.account_id, target=f"feedback:{item.id}")
    if walk is not None and body.companion_stars is not None:
        moderation.rated(
            db,
            redis,
            walk.companion_id,
            "companion",
            f"feedback:{item.id}",
            body.companion_stars,
            now,
        )
    db.commit()
    return schemas.FeedbackOut(id=item.id)


def _going_offers(db: DbDep, account_id, journey_id) -> list[ResponderOffer]:
    """Offers where a responder said "I'm going" on alerts of this traveller's journey."""
    return list(
        db.scalars(
            select(ResponderOffer)
            .join(Escalation, Escalation.id == ResponderOffer.escalation_id)
            .where(
                Escalation.journey_id == journey_id,
                Escalation.owner_id == account_id,
                ResponderOffer.status == "going",
            )
            .order_by(ResponderOffer.responded_at)
        )
    )


@router.get("/responders/{journey_id}", response_model=schemas.RespondersToRate)
def responders_to_rate(
    journey_id: uuid.UUID, session: CurrentSessionDep, db: DbDep
) -> schemas.RespondersToRate:
    """Responders who came for this journey and are not rated yet (owner only)."""
    rated = set(
        db.scalars(select(ResponderRating.offer_id).where(ResponderRating.journey_id == journey_id))
    )
    out = []
    for offer in _going_offers(db, session.account_id, journey_id):
        if offer.id in rated:
            continue
        profile = db.get(ResponderProfile, (offer.responder_id, "responder"))
        out.append(
            schemas.ResponderToRate(
                offer_id=offer.id, name=profile.display_name if profile else "Responder"
            )
        )
    return schemas.RespondersToRate(responders=out)


@router.post("/responder", response_model=schemas.FeedbackOut, status_code=201)
def rate_responder(
    body: schemas.ResponderRatingIn,
    session: CurrentSessionDep,
    db: DbDep,
    redis: RedisDep,
    now: NowDep,
) -> schemas.FeedbackOut:
    """Stars for one responder who came. A 1-star rating suspends them until an admin decides."""
    offer = db.get(ResponderOffer, body.offer_id)
    escalation = db.get(Escalation, offer.escalation_id) if offer else None
    if (
        offer is None
        or escalation is None
        or escalation.owner_id != session.account_id
        or escalation.journey_id is None
    ):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "responder_not_found")
    if db.scalar(select(ResponderRating.id).where(ResponderRating.offer_id == offer.id)):
        raise HTTPException(status.HTTP_409_CONFLICT, "feedback_already_given")
    if offer.status != "going":
        raise HTTPException(status.HTTP_404_NOT_FOUND, "responder_not_found")
    rating = ResponderRating(
        journey_id=escalation.journey_id,
        offer_id=offer.id,
        stars=body.stars,
        note=body.note,
        created_at=now,
    )
    db.add(rating)
    db.flush()
    audit.record(
        db, "feedback.responder_rated", actor=session.account_id, target=f"rating:{rating.id}"
    )
    moderation.rated(
        db,
        redis,
        offer.responder_id,
        "responder",
        f"responder_rating:{rating.id}",
        body.stars,
        now,
    )
    db.commit()
    return schemas.FeedbackOut(id=rating.id)
