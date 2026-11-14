"""helpers on an alert, verified responders, responder offers (P3-W1)

Revision ID: 0006
Revises: 0005
Create Date: 2026-11-13
"""

import sqlalchemy as sa
from alembic import op

revision = "0006"
down_revision = "0005"
branch_labels = None
depends_on = None


def _id() -> sa.Column:
    return sa.Column("id", sa.Uuid(), server_default=sa.text("gen_random_uuid()"), primary_key=True)


def _escalation_fk() -> sa.Column:
    return sa.Column(
        "escalation_id",
        sa.Uuid(),
        sa.ForeignKey("escalations.id", ondelete="CASCADE"),
        nullable=False,
    )


def upgrade() -> None:
    op.create_table(
        "escalation_helpers",
        _id(),
        _escalation_fk(),
        sa.Column(
            "account_id",
            sa.Uuid(),
            sa.ForeignKey("accounts.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("status", sa.Text(), server_default="going", nullable=False),
        sa.Column("accepted_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("arrived_at", sa.DateTime(timezone=True), nullable=True),
        sa.UniqueConstraint("escalation_id", "account_id", name="uq_escalation_helpers_account"),
        sa.CheckConstraint("kind IN ('contact', 'responder')", name="escalation_helpers_kind"),
        sa.CheckConstraint("status IN ('going', 'arrived')", name="escalation_helpers_status"),
    )
    op.create_index("ix_escalation_helpers_escalation_id", "escalation_helpers", ["escalation_id"])

    op.create_table(
        "responder_profiles",
        sa.Column(
            "account_id",
            sa.Uuid(),
            sa.ForeignKey("accounts.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column("display_name", sa.Text(), nullable=False),
        sa.Column("status", sa.Text(), server_default="pending", nullable=False),
        sa.Column("applied_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("approved_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            "status IN ('pending', 'approved', 'revoked')", name="responder_profiles_status"
        ),
    )

    op.create_table(
        "responder_offers",
        _id(),
        _escalation_fk(),
        sa.Column(
            "responder_id",
            sa.Uuid(),
            sa.ForeignKey("accounts.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("distance_m", sa.Integer(), nullable=False),
        sa.Column("offered_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("status", sa.Text(), server_default="offered", nullable=False),
        sa.Column("responded_at", sa.DateTime(timezone=True), nullable=True),
        sa.UniqueConstraint("escalation_id", "responder_id", name="uq_responder_offers_pair"),
        sa.CheckConstraint(
            "status IN ('offered', 'going', 'declined')", name="responder_offers_status"
        ),
    )
    op.create_index("ix_responder_offers_responder_id", "responder_offers", ["responder_id"])


def downgrade() -> None:
    op.drop_table("responder_offers")
    op.drop_table("responder_profiles")
    op.drop_table("escalation_helpers")
