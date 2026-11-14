"""walk with me: profiles, companions, walks, feedback; companion alert recipients

Revision ID: 0008
Revises: 0007
Create Date: 2026-11-14
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None


def _id() -> sa.Column:
    return sa.Column("id", sa.Uuid(), server_default=sa.text("gen_random_uuid()"), primary_key=True)


def _account(name: str, primary_key: bool = False) -> sa.Column:
    return sa.Column(
        name,
        sa.Uuid(),
        sa.ForeignKey("accounts.id", ondelete="CASCADE"),
        nullable=False,
        primary_key=primary_key,
        index=not primary_key,
    )


def _texts(name: str) -> sa.Column:
    return sa.Column(name, postgresql.ARRAY(sa.Text()), nullable=False, server_default="{}")


def upgrade() -> None:
    op.create_table(
        "profiles",
        _account("account_id", primary_key=True),
        sa.Column("first_name", sa.Text(), nullable=False),
        sa.Column("bio", sa.Text(), nullable=False, server_default=""),
        _texts("strengths"),
        _texts("languages"),
        sa.Column("gender", sa.Text()),
        sa.Column("willing_companion", sa.Boolean(), nullable=False, server_default="false"),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "gender IS NULL OR gender IN ('woman', 'man', 'non_binary')",
            name="profiles_gender_valid",
        ),
    )
    op.create_table(
        "companion_profiles",
        _account("account_id", primary_key=True),
        sa.Column("status", sa.Text(), nullable=False, server_default="pending"),
        sa.Column("verified_method", sa.Text(), nullable=False),
        sa.Column("verified_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("approved_at", sa.DateTime(timezone=True)),
        sa.CheckConstraint(
            "status IN ('pending', 'approved', 'revoked')", name="companion_profiles_status"
        ),
    )
    op.create_table(
        "walks",
        _id(),
        sa.Column(
            "journey_id",
            sa.Uuid(),
            sa.ForeignKey("journeys.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        _account("traveller_id"),
        _account("companion_id"),
        sa.Column("status", sa.Text(), nullable=False, server_default="requested"),
        sa.Column("requested_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("responded_at", sa.DateTime(timezone=True)),
        sa.Column("ended_at", sa.DateTime(timezone=True)),
        sa.Column("end_reason", sa.Text()),
        sa.CheckConstraint(
            "status IN ('requested', 'accepted', 'declined', 'expired', 'cancelled', 'ended')",
            name="walks_status_valid",
        ),
    )
    op.create_index(
        "uq_walks_one_open_per_traveller",
        "walks",
        ["traveller_id"],
        unique=True,
        postgresql_where=sa.text("status IN ('requested', 'accepted')"),
    )
    op.create_table(
        "feedback",
        _id(),
        sa.Column(
            "journey_id",
            sa.Uuid(),
            sa.ForeignKey("journeys.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        sa.Column("walk_id", sa.Uuid(), sa.ForeignKey("walks.id", ondelete="CASCADE"), index=True),
        sa.Column("route_stars", sa.SmallInteger(), nullable=False),
        sa.Column("companion_stars", sa.SmallInteger()),
        _texts("chips"),
        sa.Column("note", sa.Text(), nullable=False, server_default=""),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("route_stars BETWEEN 1 AND 5", name="feedback_route_stars"),
        sa.CheckConstraint(
            "companion_stars IS NULL OR companion_stars BETWEEN 1 AND 5",
            name="feedback_companion_stars",
        ),
        sa.CheckConstraint("companion_stars IS NULL OR walk_id IS NOT NULL", name="feedback_walk"),
    )
    # A walk companion alerted by an SOS may say "I'm on it" but cannot close the alarm.
    op.add_column(
        "escalation_recipients",
        sa.Column("kind", sa.Text(), nullable=False, server_default="contact"),
    )
    op.create_check_constraint(
        "escalation_recipients_kind", "escalation_recipients", "kind IN ('contact', 'companion')"
    )


def downgrade() -> None:
    op.drop_constraint("escalation_recipients_kind", "escalation_recipients")
    op.drop_column("escalation_recipients", "kind")
    op.drop_table("feedback")
    op.drop_index("uq_walks_one_open_per_traveller", table_name="walks")
    op.drop_table("walks")
    op.drop_table("companion_profiles")
    op.drop_table("profiles")
