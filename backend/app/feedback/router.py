"""POST /feedback: the journey's owner says how it went. Stored raw; nothing is computed."""

from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select

from app.core import audit
from app.feedback import schemas
from app.feedback.models import Feedback
from app.identity.router import CurrentSessionDep, DbDep
from app.journey.models import Journey

router = APIRouter(prefix="/feedback", tags=["feedback"])


def _now() -> datetime:
    return datetime.now(UTC)


NowDep = Annotated[datetime, Depends(_now)]


@router.post("", response_model=schemas.FeedbackOut, status_code=status.HTTP_201_CREATED)
def give_feedback(
    body: schemas.FeedbackIn, session: CurrentSessionDep, db: DbDep, now: NowDep
) -> schemas.FeedbackOut:
    from app.walks.models import Walk  # walks imports feedback for ratings

    journey = db.get(Journey, body.journey_id)
    if journey is None or journey.account_id != session.account_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "journey_not_found")
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
    db.commit()
    return schemas.FeedbackOut(id=item.id)
