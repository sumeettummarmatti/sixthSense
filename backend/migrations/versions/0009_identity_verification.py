"""identity verification outcomes and role-scoped responder profiles (P3-W2)

Revision ID: 0009
Revises: 0008
Create Date: 2026-11-13

Written as 0008 (after 0006) on p1/responder-verification; renumbered to follow Walk With Me's
0008 when the branches were combined on integration/verify-walk.
"""

import sqlalchemy as sa
from alembic import op

revision = "0009"
down_revision = "0008"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "verification_sessions",
        sa.Column("id", sa.Uuid(), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column(
            "account_id",
            sa.Uuid(),
            sa.ForeignKey("accounts.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("purpose", sa.Text(), nullable=False),
        sa.Column("provider", sa.Text(), nullable=False),
        sa.Column("provider_ref", sa.Text(), nullable=True),
        sa.Column("status", sa.Text(), server_default="pending", nullable=False),
        sa.Column("reason_code", sa.Text(), nullable=True),
        sa.Column("attempt_no", sa.Integer(), server_default="1", nullable=False),
        sa.Column("consent_version", sa.Text(), nullable=False),
        sa.Column("consent_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            "purpose IN ('responder', 'companion')", name="verification_sessions_purpose"
        ),
        sa.CheckConstraint(
            "provider IN ('mock', 'campus_office', 'setu')", name="verification_sessions_provider"
        ),
        sa.CheckConstraint(
            "status IN ('pending', 'verified', 'rejected', 'underage', 'expired', 'error')",
            name="verification_sessions_status",
        ),
        sa.CheckConstraint("attempt_no > 0", name="verification_sessions_attempt_positive"),
    )
    op.create_index(
        "ix_verification_sessions_account_created",
        "verification_sessions",
        ["account_id", "created_at"],
    )

    op.create_table(
        "identity_records",
        sa.Column(
            "account_id",
            sa.Uuid(),
            sa.ForeignKey("accounts.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column("id_type", sa.Text(), nullable=False),
        sa.Column("id_hmac", sa.LargeBinary(32), nullable=False, unique=True),
        sa.Column("person_hmac", sa.LargeBinary(32), nullable=False),
        sa.Column("hmac_key_version", sa.Integer(), nullable=False),
        sa.Column("is_adult", sa.Boolean(), nullable=False),
        sa.Column("verified_by", sa.Text(), nullable=False),
        sa.Column("verified_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("valid_until", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_reason", sa.Text(), nullable=True),
    )
    op.create_index("ix_identity_records_person_hmac", "identity_records", ["person_hmac"])

    op.add_column(
        "responder_profiles",
        sa.Column("role", sa.Text(), server_default="responder", nullable=False),
    )
    op.drop_constraint("responder_profiles_pkey", "responder_profiles", type_="primary")
    op.create_primary_key("responder_profiles_pkey", "responder_profiles", ["account_id", "role"])
    op.create_check_constraint(
        "responder_profiles_role", "responder_profiles", "role IN ('responder', 'companion')"
    )

    # revoked_at already exists and is used by auth + relay routing.
    op.add_column("devices", sa.Column("key_rotated_at", sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column("devices", "key_rotated_at")
    op.drop_constraint("responder_profiles_role", "responder_profiles", type_="check")
    op.drop_constraint("responder_profiles_pkey", "responder_profiles", type_="primary")
    op.create_primary_key("responder_profiles_pkey", "responder_profiles", ["account_id"])
    op.drop_column("responder_profiles", "role")
    op.drop_index("ix_identity_records_person_hmac", table_name="identity_records")
    op.drop_table("identity_records")
    op.drop_index("ix_verification_sessions_account_created", table_name="verification_sessions")
    op.drop_table("verification_sessions")
