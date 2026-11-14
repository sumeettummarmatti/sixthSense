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
    key_rotated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # FCM registration token, encrypted with DATA_KEY (P2-W4); NULL until the app sends it
    fcm_token_enc: Mapped[bytes | None] = mapped_column(LargeBinary)


class DeviceE2EKeys(Base):
    """Public keys a device uses for end-to-end location sharing (P1-W6 envelope).

    Separate from the P-256 sign-in key: the envelope needs X25519 (key agreement) and
    Ed25519 (sender signatures). Uploading new keys replaces the old ones with a new key_id.
    """

    __tablename__ = "device_e2e_keys"

    device_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("devices.id", ondelete="CASCADE"), primary_key=True
    )
    key_id: Mapped[uuid.UUID]
    x25519_public_key: Mapped[bytes] = mapped_column(LargeBinary(32))
    ed25519_public_key: Mapped[bytes] = mapped_column(LargeBinary(32))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
