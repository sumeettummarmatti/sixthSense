import uuid
from datetime import datetime

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    LargeBinary,
    Text,
    func,
    text,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class TrustedContact(Base):
    """A link from an owner to a contact account. Pending until the contact accepts the invite.

    Removal deletes the row (silent: the contact is never told).
    """

    __tablename__ = "trusted_contacts"
    __table_args__ = (
        CheckConstraint("owner_id <> contact_id", name="trusted_contacts_not_self"),
        CheckConstraint(
            "char_length(owner_label) BETWEEN 1 AND 40", name="trusted_contacts_label_length"
        ),
        Index(
            "uq_trusted_contacts_owner_contact",
            "owner_id",
            "contact_id",
            unique=True,
            postgresql_where=text("contact_id IS NOT NULL"),
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, server_default=func.gen_random_uuid())
    owner_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), index=True
    )
    contact_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), index=True
    )
    # Name the owner chose to show the contact in alerts ("Priya"). Not the contact's name.
    owner_label: Mapped[str] = mapped_column(Text)
    # HMAC(TOKEN_SECRET, invite token); the token itself exists only in the shared link.
    invite_hash: Mapped[bytes] = mapped_column(LargeBinary(32), unique=True)
    invite_expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    accepted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
