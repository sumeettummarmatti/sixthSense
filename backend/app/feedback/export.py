"""Feedback rows for admins (CLI script and admin page share this). Ids, stars, chips, note."""

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.feedback.models import Feedback

COLUMNS = (
    "id",
    "journey_id",
    "walk_id",
    "route_stars",
    "companion_stars",
    "chips",
    "note",
    "created_at",
)


def rows(db: Session) -> list[dict]:
    items = db.scalars(select(Feedback).order_by(Feedback.created_at)).all()
    return [
        {
            "id": str(f.id),
            "journey_id": str(f.journey_id),
            "walk_id": str(f.walk_id) if f.walk_id else "",
            "route_stars": f.route_stars,
            "companion_stars": f.companion_stars if f.companion_stars is not None else "",
            "chips": ";".join(f.chips),
            "note": f.note,
            "created_at": f.created_at.isoformat(),
        }
        for f in items
    ]
