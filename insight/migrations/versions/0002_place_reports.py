"""place reports (cell-level, anonymous)

Revision ID: 0002
Revises: 0001
Create Date: 2026-11-13
"""

import sqlalchemy as sa
from alembic import op

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "place_reports",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("cell_lat", sa.Float(), nullable=False),
        sa.Column("cell_lon", sa.Float(), nullable=False),
        sa.Column("category", sa.String(32), nullable=False),
        sa.Column("reporter_hash", sa.String(64), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index(
        "ix_place_reports_cell_time", "place_reports", ["cell_lat", "cell_lon", "created_at"]
    )
    op.create_index(
        "ix_place_reports_reporter_time", "place_reports", ["reporter_hash", "created_at"]
    )


def downgrade() -> None:
    op.drop_index("ix_place_reports_reporter_time", table_name="place_reports")
    op.drop_index("ix_place_reports_cell_time", table_name="place_reports")
    op.drop_table("place_reports")
