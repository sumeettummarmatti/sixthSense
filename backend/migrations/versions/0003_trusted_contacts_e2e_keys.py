"""trusted contacts and device E2E keys (P2-W2)

Revision ID: 0003
Revises: 0002
Create Date: 2026-11-11
"""

import sqlalchemy as sa
from alembic import op

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "trusted_contacts",
        sa.Column("id", sa.Uuid(), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column(
            "owner_id", sa.Uuid(), sa.ForeignKey("accounts.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column(
            "contact_id", sa.Uuid(), sa.ForeignKey("accounts.id", ondelete="CASCADE"), nullable=True
        ),
        sa.Column("owner_label", sa.Text(), nullable=False),
        sa.Column("invite_hash", sa.LargeBinary(32), nullable=False, unique=True),
        sa.Column("invite_expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column("accepted_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint("owner_id <> contact_id", name="trusted_contacts_not_self"),
        sa.CheckConstraint(
            "char_length(owner_label) BETWEEN 1 AND 40", name="trusted_contacts_label_length"
        ),
    )
    op.create_index("ix_trusted_contacts_owner_id", "trusted_contacts", ["owner_id"])
    op.create_index("ix_trusted_contacts_contact_id", "trusted_contacts", ["contact_id"])
    op.create_index(
        "uq_trusted_contacts_owner_contact",
        "trusted_contacts",
        ["owner_id", "contact_id"],
        unique=True,
        postgresql_where=sa.text("contact_id IS NOT NULL"),
    )

    op.create_table(
        "device_e2e_keys",
        sa.Column(
            "device_id",
            sa.Uuid(),
            sa.ForeignKey("devices.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column("key_id", sa.Uuid(), nullable=False),
        sa.Column("x25519_public_key", sa.LargeBinary(32), nullable=False),
        sa.Column("ed25519_public_key", sa.LargeBinary(32), nullable=False),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
    )


def downgrade() -> None:
    op.drop_table("device_e2e_keys")
    op.drop_index("uq_trusted_contacts_owner_contact", table_name="trusted_contacts")
    op.drop_index("ix_trusted_contacts_contact_id", table_name="trusted_contacts")
    op.drop_index("ix_trusted_contacts_owner_id", table_name="trusted_contacts")
    op.drop_table("trusted_contacts")
