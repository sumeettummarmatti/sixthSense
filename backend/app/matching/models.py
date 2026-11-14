import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Integer, Text, UniqueConstraint, func
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class ResponderProfile(Base):
    """A person who offered to help strangers nearby. Only approved responders are matched
    (rule 1: helpers are verified; protection itself never needs ID). The pilot approves by
    hand (scripts/responders.py); real verification comes later (Docs: verification)."""

    __tablename__ = "responder_profiles"

    account_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), primary_key=True
    )
    role: Mapped[str] = mapped_column(Text, primary_key=True, default="responder")
    display_name: Mapped[str] = mapped_column(Text)
    status: Mapped[str] = mapped_column(Text, server_default="pending")  # pending|approved|revoked
    applied_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    approved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class ResponderOffer(Base):
    """One responder asked to help with one alert. Deleted with the alert (90 days)."""

    __tablename__ = "responder_offers"
    __table_args__ = (
        UniqueConstraint("escalation_id", "responder_id", name="uq_responder_offers_pair"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, server_default=func.gen_random_uuid())
    escalation_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("escalations.id", ondelete="CASCADE")
    )
    responder_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), index=True
    )
    distance_m: Mapped[int] = mapped_column(Integer)  # from rough areas, at offer time
    offered_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    status: Mapped[str] = mapped_column(Text, server_default="offered")  # offered|going|declined
    responded_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
