import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, LargeBinary, func
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class AlertChannels(Base):
    """How a contact can be reached besides push. Both are opt-in and encrypted (DATA_KEY)."""

    __tablename__ = "alert_channels"

    account_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), primary_key=True
    )
    telegram_chat_id_enc: Mapped[bytes | None] = mapped_column(LargeBinary)
    email_enc: Mapped[bytes | None] = mapped_column(LargeBinary)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
