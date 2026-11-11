"""alert channels, escalations, recipients, device FCM token, journey ack (P2-W4)

Revision ID: 0005
Revises: 0004
Create Date: 2026-11-11
"""

import sqlalchemy as sa
from alembic import op

revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("devices", sa.Column("fcm_token_enc", sa.LargeBinary(), nullable=True))
    op.add_column(
        "journeys", sa.Column("alert_acknowledged_at", sa.DateTime(timezone=True), nullable=True)
    )
    op.create_table(
        "alert_channels",
        sa.Column(
            "account_id",
            sa.Uuid(),
            sa.ForeignKey("accounts.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column("telegram_chat_id_enc", sa.LargeBinary(), nullable=True),
        sa.Column("email_enc", sa.LargeBinary(), nullable=True),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
    )
    op.create_table(
        "escalations",
        sa.Column("id", sa.Uuid(), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column(
            "journey_id",
            sa.Uuid(),
            sa.ForeignKey("journeys.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column(
            "owner_id", sa.Uuid(), sa.ForeignKey("accounts.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("level", sa.Text(), nullable=False),
        sa.Column("covert", sa.Boolean(), server_default="false", nullable=False),
        sa.Column("opened_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("acknowledged_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("acknowledged_by", sa.Uuid(), nullable=True),
        sa.Column("closed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("close_reason", sa.Text(), nullable=True),
        sa.CheckConstraint(
            "level IN ('contact_alert', 'full_escalation')", name="escalations_level_valid"
        ),
    )
    op.create_index("ix_escalations_owner_id", "escalations", ["owner_id"])
    op.create_index(
        "uq_escalations_open_journey_level",
        "escalations",
        ["journey_id", "level"],
        unique=True,
        postgresql_where=sa.text("closed_at IS NULL"),
    )
    op.create_table(
        "escalation_recipients",
        sa.Column("id", sa.Uuid(), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column(
            "escalation_id",
            sa.Uuid(),
            sa.ForeignKey("escalations.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "contact_account_id",
            sa.Uuid(),
            sa.ForeignKey("accounts.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("owner_label", sa.Text(), nullable=False),
        sa.Column("ack_token_hash", sa.LargeBinary(32), nullable=False, unique=True),
        sa.Column("ack_token_enc", sa.LargeBinary(), nullable=False),
        sa.Column("step", sa.SmallInteger(), server_default="0", nullable=False),
        sa.Column("cycle", sa.SmallInteger(), server_default="0", nullable=False),
        sa.Column("next_attempt_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_channel", sa.Text(), nullable=True),
        sa.UniqueConstraint(
            "escalation_id", "contact_account_id", name="uq_escalation_recipients_contact"
        ),
    )
    op.create_index(
        "ix_escalation_recipients_escalation_id", "escalation_recipients", ["escalation_id"]
    )


def downgrade() -> None:
    op.drop_index("ix_escalation_recipients_escalation_id", table_name="escalation_recipients")
    op.drop_table("escalation_recipients")
    op.drop_index("uq_escalations_open_journey_level", table_name="escalations")
    op.drop_index("ix_escalations_owner_id", table_name="escalations")
    op.drop_table("escalations")
    op.drop_table("alert_channels")
    op.drop_column("journeys", "alert_acknowledged_at")
    op.drop_column("devices", "fcm_token_enc")
