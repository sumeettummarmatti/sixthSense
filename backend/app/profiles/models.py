import uuid
from datetime import datetime

from sqlalchemy import Boolean, CheckConstraint, DateTime, ForeignKey, Text
from sqlalchemy.dialects.postgresql import ARRAY
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class Profile(Base):
    """What a walk partner may see about me. Nothing here is required for protection (rule 1)."""

    __tablename__ = "profiles"
    __table_args__ = (
        CheckConstraint(
            "gender IS NULL OR gender IN ('woman', 'man', 'non_binary')",
            name="profiles_gender_valid",
        ),
    )

    account_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), primary_key=True
    )
    first_name: Mapped[str] = mapped_column(Text)
    bio: Mapped[str] = mapped_column(Text, server_default="")
    strengths: Mapped[list[str]] = mapped_column(ARRAY(Text), server_default="{}")
    languages: Mapped[list[str]] = mapped_column(ARRAY(Text), server_default="{}")
    gender: Mapped[str | None] = mapped_column(Text)
    willing_companion: Mapped[bool] = mapped_column(Boolean, server_default="false")
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
