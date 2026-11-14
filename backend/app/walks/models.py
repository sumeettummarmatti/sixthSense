import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, Index, Text, func, text
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class CompanionProfile(Base):
    """Someone who joined Walk With Me as a companion. Companions are verified (rule 1) through
    identity verification (ID + selfie); there is no approval step. status 'approved' means
    joined, 'revoked' removes them (scripts/companions.py revoke)."""

    __tablename__ = "companion_profiles"
    __table_args__ = (
        CheckConstraint(
            "status IN ('pending', 'approved', 'revoked')", name="companion_profiles_status"
        ),
    )

    account_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), primary_key=True
    )
    status: Mapped[str] = mapped_column(Text, server_default="pending")
    verified_method: Mapped[str] = mapped_column(Text)  # 'identity' (older rows: 'mock')
    verified_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    approved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


WALK_STATUSES = ("requested", "accepted", "declined", "expired", "cancelled", "ended")


class Walk(Base):
    """One request from a traveller to a companion, and the walk if accepted. No location is
    stored: the traveller's rough area lives in Redis while the walk is open."""

    __tablename__ = "walks"
    __table_args__ = (
        CheckConstraint(
            "status IN ('requested', 'accepted', 'declined', 'expired', 'cancelled', 'ended')",
            name="walks_status_valid",
        ),
        Index(
            "uq_walks_one_open_per_traveller",
            "traveller_id",
            unique=True,
            postgresql_where=text("status IN ('requested', 'accepted')"),
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, server_default=func.gen_random_uuid())
    journey_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("journeys.id", ondelete="CASCADE"), index=True
    )
    traveller_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), index=True
    )
    companion_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), index=True
    )
    status: Mapped[str] = mapped_column(Text, server_default="requested")
    requested_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    responded_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    end_reason: Mapped[str | None] = mapped_column(Text)  # traveller|companion|journey_over
