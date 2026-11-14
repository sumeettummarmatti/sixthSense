import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, SmallInteger, Text, func
from sqlalchemy.dialects.postgresql import ARRAY
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class Feedback(Base):
    """Raw feedback. Deliberately no location and no names: ids, stars, chips, a short note."""

    __tablename__ = "feedback"
    __table_args__ = (
        CheckConstraint("route_stars BETWEEN 1 AND 5", name="feedback_route_stars"),
        CheckConstraint(
            "companion_stars IS NULL OR companion_stars BETWEEN 1 AND 5",
            name="feedback_companion_stars",
        ),
        CheckConstraint("companion_stars IS NULL OR walk_id IS NOT NULL", name="feedback_walk"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, server_default=func.gen_random_uuid())
    journey_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("journeys.id", ondelete="CASCADE"), index=True
    )
    walk_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("walks.id", ondelete="CASCADE"), index=True
    )
    route_stars: Mapped[int] = mapped_column(SmallInteger)
    companion_stars: Mapped[int | None] = mapped_column(SmallInteger)
    chips: Mapped[list[str]] = mapped_column(ARRAY(Text), server_default="{}")
    note: Mapped[str] = mapped_column(Text, server_default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
