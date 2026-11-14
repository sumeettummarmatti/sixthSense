import uuid
from datetime import datetime

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    LargeBinary,
    SmallInteger,
    Text,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class Escalation(Base):
    """One alert for one journey at one level. Idempotent: one OPEN row per (journey, level),
    so a journey that calms down and escalates again gets a fresh alert.

    Kept 90 days (HLD §8). journey_id is set to NULL when the journey is purged after 7 days.
    """

    __tablename__ = "escalations"
    __table_args__ = (
        Index(
            "uq_escalations_open_journey_level",
            "journey_id",
            "level",
            unique=True,
            postgresql_where=text("closed_at IS NULL"),
        ),
        CheckConstraint(
            "level IN ('contact_alert', 'full_escalation')", name="escalations_level_valid"
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, server_default=func.gen_random_uuid())
    journey_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("journeys.id", ondelete="SET NULL")
    )
    owner_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), index=True
    )
    level: Mapped[str] = mapped_column(Text)
    covert: Mapped[bool] = mapped_column(Boolean, server_default="false")
    opened_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    acknowledged_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    acknowledged_by: Mapped[uuid.UUID | None]
    closed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # owner_checked_in | resolved_by_contact | journey_ended | superseded
    close_reason: Mapped[str | None] = mapped_column(Text)


class EscalationRecipient(Base):
    """One contact being alerted, with their place on the push -> telegram -> email ladder."""

    __tablename__ = "escalation_recipients"
    __table_args__ = (
        UniqueConstraint(
            "escalation_id", "contact_account_id", name="uq_escalation_recipients_contact"
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, server_default=func.gen_random_uuid())
    escalation_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("escalations.id", ondelete="CASCADE"), index=True
    )
    contact_account_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE")
    )
    owner_label: Mapped[str] = mapped_column(Text)
    # Ack link token: hash for lookup, encrypted copy to rebuild the link for each message.
    ack_token_hash: Mapped[bytes] = mapped_column(LargeBinary(32), unique=True)
    ack_token_enc: Mapped[bytes] = mapped_column(LargeBinary)
    step: Mapped[int] = mapped_column(SmallInteger, server_default="0")
    cycle: Mapped[int] = mapped_column(SmallInteger, server_default="0")
    next_attempt_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_channel: Mapped[str | None] = mapped_column(Text)
    # contact = trusted contact; companion = Walk With Me partner during an SOS (may say
    # "I'm on it", may not close the alarm).
    kind: Mapped[str] = mapped_column(Text, server_default="contact")


class EscalationHelper(Base):
    """Someone who said they are going to help: a trusted contact ("I'm on it") or a verified
    responder ("I'm going"). The traveller sees who is coming; helpers share their location
    back to the traveller only, end to end encrypted, while the alert is open (rule 4)."""

    __tablename__ = "escalation_helpers"
    __table_args__ = (
        UniqueConstraint("escalation_id", "account_id", name="uq_escalation_helpers_account"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, server_default=func.gen_random_uuid())
    escalation_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("escalations.id", ondelete="CASCADE"), index=True
    )
    account_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("accounts.id", ondelete="CASCADE"))
    kind: Mapped[str] = mapped_column(Text)  # contact | responder
    status: Mapped[str] = mapped_column(Text, server_default="going")  # going | arrived
    accepted_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    arrived_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
