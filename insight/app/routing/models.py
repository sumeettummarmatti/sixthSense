from datetime import datetime

from sqlalchemy import DateTime, Float, Index, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base


class PlaceReport(Base):
    """One anonymous report about a place (rule 6). A ~55 m cell, a category, a time, and an
    HMAC of an opaque reporter token used only for the "m distinct reporters" publish threshold.
    No finer coordinates, no account, no device id, no free text."""

    __tablename__ = "place_reports"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    cell_lat: Mapped[float] = mapped_column(Float, nullable=False)
    cell_lon: Mapped[float] = mapped_column(Float, nullable=False)
    category: Mapped[str] = mapped_column(String(32), nullable=False)
    reporter_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)

    __table_args__ = (
        Index("ix_place_reports_cell_time", "cell_lat", "cell_lon", "created_at"),
        Index("ix_place_reports_reporter_time", "reporter_hash", "created_at"),
    )
