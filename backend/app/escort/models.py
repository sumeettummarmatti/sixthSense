import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, Index, Text, Uuid, func, text
from sqlalchemy.dialects.postgresql import ARRAY
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class AudioEscort(Base):
    """Who may hear the owner's live audio, and until when. One running escort per journey."""

    __tablename__ = "audio_escorts"
    __table_args__ = (
        CheckConstraint(
            "end_reason IS NULL OR end_reason IN ('stopped', 'expired', 'duress', 'journey_over')",
            name="audio_escorts_end_reason_valid",
        ),
        Index(
            "uq_audio_escorts_one_running_per_journey",
            "journey_id",
            unique=True,
            postgresql_where=text("ended_at IS NULL"),
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, server_default=func.gen_random_uuid())
    journey_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("journeys.id", ondelete="CASCADE"), index=True
    )
    account_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), index=True
    )
    # trusted_contacts ids of the people listening
    listener_link_ids: Mapped[list[uuid.UUID]] = mapped_column(ARRAY(Uuid))
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    ends_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    end_reason: Mapped[str | None] = mapped_column(Text)


class EscortRequest(Base):
    """A contact asking the owner to start an escort. The owner must accept on their phone."""

    __tablename__ = "escort_requests"
    __table_args__ = (
        CheckConstraint(
            "status IN ('pending', 'accepted', 'declined')", name="escort_requests_status_valid"
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, server_default=func.gen_random_uuid())
    link_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("trusted_contacts.id", ondelete="CASCADE"), index=True
    )
    owner_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), index=True
    )
    requester_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("accounts.id", ondelete="CASCADE"))
    status: Mapped[str] = mapped_column(Text, server_default="pending")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    responded_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
