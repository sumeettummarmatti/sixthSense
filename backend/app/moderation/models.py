import uuid
from datetime import datetime

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    ForeignKey,
    LargeBinary,
    SmallInteger,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class ResponderRating(Base):
    """A traveller's stars for one responder who said "I'm going". No location, no names."""

    __tablename__ = "responder_ratings"
    __table_args__ = (
        UniqueConstraint("offer_id", name="uq_responder_ratings_offer"),
        CheckConstraint("stars BETWEEN 1 AND 5", name="responder_ratings_stars"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, server_default=func.gen_random_uuid())
    journey_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("journeys.id", ondelete="CASCADE"), index=True
    )
    offer_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("responder_offers.id", ondelete="SET NULL")
    )
    stars: Mapped[int] = mapped_column(SmallInteger)
    note: Mapped[str] = mapped_column(Text, server_default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class ModerationCase(Base):
    """A helper flagged by a bad rating (or by an admin). Admins see the case id, never who.

    suspended: cannot help (1-star rating), waiting for an admin.
    banned: the account is blocked from the whole app; face/ID kept in banned_identities.
    restored: an admin cleared it; the helper can help again.
    """

    __tablename__ = "moderation_cases"
    __table_args__ = (
        CheckConstraint(
            "status IN ('suspended', 'banned', 'restored')", name="moderation_cases_status"
        ),
        CheckConstraint("role IN ('companion', 'responder')", name="moderation_cases_role"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, server_default=func.gen_random_uuid())
    account_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), index=True
    )
    role: Mapped[str] = mapped_column(Text)
    source: Mapped[str] = mapped_column(Text)  # feedback:<id> | responder_rating:<id> | admin
    stars: Mapped[int | None] = mapped_column(SmallInteger)
    status: Mapped[str] = mapped_column(Text)
    opened_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    decided_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class BannedIdentity(Base):
    """What stops a banned person verifying again: keyed ID hashes and the encrypted face
    embedding. No account link, so it survives the account being deleted."""

    __tablename__ = "banned_identities"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, server_default=func.gen_random_uuid())
    case_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("moderation_cases.id", ondelete="SET NULL")
    )
    id_hmac: Mapped[bytes | None] = mapped_column(LargeBinary(32), index=True)
    person_hmac: Mapped[bytes | None] = mapped_column(LargeBinary(32), index=True)
    embedding_enc: Mapped[bytes | None] = mapped_column(LargeBinary)
    calculator_version: Mapped[str | None] = mapped_column(Text)
    banned_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
