import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, LargeBinary, SmallInteger, Text, func
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class Account(Base):
    """A Tier 0 traveller or above. No plaintext email, name or phone is stored here (rule 2)."""

    __tablename__ = "accounts"
    __table_args__ = (
        CheckConstraint("status IN ('active', 'suspended')", name="accounts_status_valid"),
        CheckConstraint("tier BETWEEN 0 AND 3", name="accounts_tier_valid"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, server_default=func.gen_random_uuid())
    # HMAC-SHA256(OTP_PEPPER, normalised email)
    email_hmac: Mapped[bytes] = mapped_column(LargeBinary(32), unique=True)
    tier: Mapped[int] = mapped_column(SmallInteger, server_default="0")
    status: Mapped[str] = mapped_column(Text, server_default="active")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class Device(Base):
    """A phone bound to an account by its Android Keystore EC P-256 public key."""

    __tablename__ = "devices"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, server_default=func.gen_random_uuid())
    account_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), index=True
    )
    # X.509 SubjectPublicKeyInfo, DER
    public_key: Mapped[bytes] = mapped_column(LargeBinary)
    # SHA-256 of public_key; one key belongs to one device only
    key_fingerprint: Mapped[bytes] = mapped_column(LargeBinary(32), unique=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    last_seen_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
