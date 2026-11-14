"""verified identity replaces manual approval for responders and companions

Revision ID: 0011
Revises: 0010
Create Date: 2026-11-14

Identity verification (ID + selfie) is now enough to act as a responder or companion; the
campus "waiting for approval" step is gone. Rows still waiting become active. Revoked rows stay
revoked: revoking remains the way to remove someone after a complaint. Eligibility is still
checked on every action (verified, adult, not expired, not revoked).
"""

from alembic import op

revision = "0011"
down_revision = "0010"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        "UPDATE responder_profiles SET status = 'approved', approved_at = now() "
        "WHERE status = 'pending'"
    )
    op.execute(
        "UPDATE companion_profiles SET status = 'approved', approved_at = now() "
        "WHERE status = 'pending'"
    )


def downgrade() -> None:
    # Approval history is not reconstructable; leave rows as they are.
    pass
