"""audio escorts and escort requests (P1-W3-audio-escort)

Revision ID: 0007
Revises: 0006
Create Date: 2026-11-13
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0007"
down_revision = "0006"
branch_labels = None
depends_on = None


def _id() -> sa.Column:
    return sa.Column("id", sa.Uuid(), server_default=sa.text("gen_random_uuid()"), primary_key=True)


def _account(name: str, index: bool = True) -> sa.Column:
    return sa.Column(
        name,
        sa.Uuid(),
        sa.ForeignKey("accounts.id", ondelete="CASCADE"),
        nullable=False,
        index=index,
    )


def upgrade() -> None:
    op.create_table(
        "audio_escorts",
        _id(),
        sa.Column(
            "journey_id",
            sa.Uuid(),
            sa.ForeignKey("journeys.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        _account("account_id"),
        sa.Column("listener_link_ids", postgresql.ARRAY(sa.Uuid()), nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ends_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ended_at", sa.DateTime(timezone=True)),
        sa.Column("end_reason", sa.Text()),
        sa.CheckConstraint(
            "end_reason IS NULL OR end_reason IN ('stopped', 'expired', 'duress', 'journey_over')",
            name="audio_escorts_end_reason_valid",
        ),
    )
    op.create_index(
        "uq_audio_escorts_one_running_per_journey",
        "audio_escorts",
        ["journey_id"],
        unique=True,
        postgresql_where=sa.text("ended_at IS NULL"),
    )
    op.create_table(
        "escort_requests",
        _id(),
        sa.Column(
            "link_id",
            sa.Uuid(),
            sa.ForeignKey("trusted_contacts.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        _account("owner_id"),
        _account("requester_id", index=False),
        sa.Column("status", sa.Text(), server_default="pending", nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("responded_at", sa.DateTime(timezone=True)),
        sa.CheckConstraint(
            "status IN ('pending', 'accepted', 'declined')", name="escort_requests_status_valid"
        ),
    )


def downgrade() -> None:
    op.drop_table("escort_requests")
    op.drop_index("uq_audio_escorts_one_running_per_journey", table_name="audio_escorts")
    op.drop_table("audio_escorts")
