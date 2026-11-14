"""responder ratings, moderation cases and the ban list (P2-W4-helper-ban)

Revision ID: 0012
Revises: 0011
Create Date: 2026-11-15

A traveller rates each responder who came. A 1-star rating of a companion or responder opens a
moderation case and suspends them from helping. An admin then bans (account blocked; keyed ID
hashes and the encrypted face embedding go to banned_identities so they cannot verify again)
or restores them.
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0012"
down_revision = "0011"
branch_labels = None
depends_on = None

_UUID = postgresql.UUID(as_uuid=True)
_TS = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.create_table(
        "responder_ratings",
        sa.Column("id", _UUID, primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column(
            "journey_id", _UUID, sa.ForeignKey("journeys.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column(
            "offer_id", _UUID, sa.ForeignKey("responder_offers.id", ondelete="SET NULL")
        ),
        sa.Column("stars", sa.SmallInteger(), nullable=False),
        sa.Column("note", sa.Text(), nullable=False, server_default=""),
        sa.Column("created_at", _TS, nullable=False),
        sa.UniqueConstraint("offer_id", name="uq_responder_ratings_offer"),
        sa.CheckConstraint("stars BETWEEN 1 AND 5", name="responder_ratings_stars"),
    )
    op.create_index("ix_responder_ratings_journey_id", "responder_ratings", ["journey_id"])

    op.create_table(
        "moderation_cases",
        sa.Column("id", _UUID, primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column(
            "account_id", _UUID, sa.ForeignKey("accounts.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("role", sa.Text(), nullable=False),
        sa.Column("source", sa.Text(), nullable=False),
        sa.Column("stars", sa.SmallInteger()),
        sa.Column("status", sa.Text(), nullable=False),
        sa.Column("opened_at", _TS, nullable=False),
        sa.Column("decided_at", _TS),
        sa.CheckConstraint(
            "status IN ('suspended', 'banned', 'restored')", name="moderation_cases_status"
        ),
        sa.CheckConstraint("role IN ('companion', 'responder')", name="moderation_cases_role"),
    )
    op.create_index("ix_moderation_cases_account_id", "moderation_cases", ["account_id"])

    op.create_table(
        "banned_identities",
        sa.Column("id", _UUID, primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column(
            "case_id", _UUID, sa.ForeignKey("moderation_cases.id", ondelete="SET NULL")
        ),
        sa.Column("id_hmac", sa.LargeBinary(32)),
        sa.Column("person_hmac", sa.LargeBinary(32)),
        sa.Column("embedding_enc", sa.LargeBinary()),
        sa.Column("calculator_version", sa.Text()),
        sa.Column("banned_at", _TS, nullable=False),
    )
    op.create_index("ix_banned_identities_id_hmac", "banned_identities", ["id_hmac"])
    op.create_index("ix_banned_identities_person_hmac", "banned_identities", ["person_hmac"])


def downgrade() -> None:
    op.drop_table("banned_identities")
    op.drop_table("moderation_cases")
    op.drop_table("responder_ratings")
