import uuid
from datetime import datetime

from sqlalchemy import (
    Boolean,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    LargeBinary,
    Text,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class VerificationSession(Base):
    """One consented verification attempt. Raw document/DOB values are never stored here."""

    __tablename__ = "verification_sessions"
    __table_args__ = (
        Index("ix_verification_sessions_account_created", "account_id", "created_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, server_default=func.gen_random_uuid())
    account_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), nullable=False
    )
    purpose: Mapped[str] = mapped_column(Text)  # responder | companion
    provider: Mapped[str] = mapped_column(Text)  # mock | campus_office | setu
    provider_ref: Mapped[str | None] = mapped_column(Text)
    status: Mapped[str] = mapped_column(Text, server_default="pending")
    reason_code: Mapped[str | None] = mapped_column(Text)
    attempt_no: Mapped[int] = mapped_column(Integer, server_default="1")
    consent_version: Mapped[str] = mapped_column(Text)
    consent_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    face_template_consent: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default="false"
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class IdentityRecord(Base):
    """Minimal verification outcome and keyed duplicate-detection hashes; no raw ID or DOB."""

    __tablename__ = "identity_records"
    __table_args__ = (Index("ix_identity_records_person_hmac", "person_hmac"),)

    account_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), primary_key=True
    )
    id_type: Mapped[str] = mapped_column(Text)
    id_hmac: Mapped[bytes] = mapped_column(LargeBinary(32), unique=True)
    person_hmac: Mapped[bytes] = mapped_column(LargeBinary(32))
    hmac_key_version: Mapped[int] = mapped_column(Integer)
    is_adult: Mapped[bool] = mapped_column(Boolean)
    verified_by: Mapped[str] = mapped_column(Text)
    verified_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    valid_until: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    revoked_reason: Mapped[str | None] = mapped_column(Text)


class FaceTemplate(Base):
    """Encrypted reusable biometric reference; no source document or image is retained."""

    __tablename__ = "face_templates"

    account_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), primary_key=True
    )
    embedding_enc: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)
    calculator_version: Mapped[str] = mapped_column(Text, nullable=False)
    consent_version: Mapped[str] = mapped_column(Text, nullable=False)
    consent_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
