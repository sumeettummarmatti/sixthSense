"""Append-only audit log for sensitive actions (rule 7).

Rows record who did what and when, never personal data: actors and targets are internal IDs.
The database rejects UPDATE and DELETE on this table (trigger in migration 0002).
"""

import uuid
from datetime import datetime

from sqlalchemy import BigInteger, DateTime, Identity, Text, func
from sqlalchemy.orm import Mapped, Session, mapped_column

from app.core.db import Base


class AuditEvent(Base):
    __tablename__ = "audit_events"

    id: Mapped[int] = mapped_column(BigInteger, Identity(), primary_key=True)
    occurred_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    actor_account_id: Mapped[uuid.UUID | None]
    action: Mapped[str] = mapped_column(Text)
    target: Mapped[str | None] = mapped_column(Text)


def record(
    db: Session, action: str, actor: uuid.UUID | None = None, target: str | None = None
) -> None:
    """Add an audit row to the caller's transaction."""
    db.add(AuditEvent(action=action, actor_account_id=actor, target=target))
