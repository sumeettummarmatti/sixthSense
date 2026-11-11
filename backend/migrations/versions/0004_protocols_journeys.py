"""protocols and journeys (P2-W3)

Revision ID: 0004
Revises: 0003
Create Date: 2026-11-11
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import ARRAY

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None


def _timer_columns() -> list[sa.Column]:
    return [
        sa.Column("check_in_interval_min", sa.SmallInteger(), server_default="15", nullable=False),
        sa.Column("check_in_grace_min", sa.SmallInteger(), server_default="2", nullable=False),
        sa.Column("prompt_timeout_min", sa.SmallInteger(), server_default="2", nullable=False),
        sa.Column("contact_response_min", sa.SmallInteger(), server_default="5", nullable=False),
        sa.Column("heartbeat_timeout_min", sa.SmallInteger(), server_default="10", nullable=False),
        sa.Column("auto_112", sa.Boolean(), server_default="false", nullable=False),
        sa.Column("alert_contact_ids", ARRAY(sa.Uuid()), nullable=True),
    ]


def upgrade() -> None:
    op.create_table(
        "protocols",
        sa.Column(
            "account_id",
            sa.Uuid(),
            sa.ForeignKey("accounts.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        *_timer_columns(),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
    )
    op.create_table(
        "journeys",
        sa.Column("id", sa.Uuid(), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column(
            "account_id",
            sa.Uuid(),
            sa.ForeignKey("accounts.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("state", sa.Text(), nullable=False),
        sa.Column("covert", sa.Boolean(), server_default="false", nullable=False),
        sa.Column("outcome", sa.Text(), nullable=True),
        *_timer_columns(),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("next_check_in_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_heartbeat_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("state_changed_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ended_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("cover_ended_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            "state IN ('active', 'check_in_due', 'private_prompt', 'contact_alert', "
            "'full_escalation', 'resolved')",
            name="journeys_state_valid",
        ),
    )
    op.create_index(
        "uq_journeys_one_open_per_account",
        "journeys",
        ["account_id"],
        unique=True,
        postgresql_where=sa.text("state <> 'resolved' AND NOT covert"),
    )
    op.create_index(
        "ix_journeys_unresolved_state",
        "journeys",
        ["state"],
        postgresql_where=sa.text("state <> 'resolved'"),
    )


def downgrade() -> None:
    op.drop_index("ix_journeys_unresolved_state", table_name="journeys")
    op.drop_index("uq_journeys_one_open_per_account", table_name="journeys")
    op.drop_table("journeys")
    op.drop_table("protocols")
