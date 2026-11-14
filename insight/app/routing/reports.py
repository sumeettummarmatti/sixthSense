"""Anonymous place reports that feed route scoring (rule 6: about places, never people).

Per report we keep a ~55 m grid cell, a category, a time and an HMAC of an opaque token the app
sends, so the k-reports / m-distinct-reporters publish threshold (risk/labels.py) can be applied.
Published cells are the only thing the scorer and the map ever see; a cell below threshold does
not exist to them. Evidence fades: each report's weight halves every `half_life_days`.
"""

import hashlib
import hmac
import math
from collections import defaultdict
from datetime import UTC, datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.risk.labels import is_publishable
from app.routing.geo import LatLon
from app.routing.models import PlaceReport
from app.routing.scoring import ReportCell

CELL_DEG = 0.0005  # ~55 m
CATEGORIES = ("dark", "no_footpath", "harassment", "unsafe_crossing", "other")


def snap_cell(lat: float, lon: float) -> LatLon:
    """Centre of the cell containing the point; the only location detail we keep."""
    return (
        round((math.floor(lat / CELL_DEG) + 0.5) * CELL_DEG, 6),
        round((math.floor(lon / CELL_DEG) + 0.5) * CELL_DEG, 6),
    )


def reporter_hash(token: str, pepper: str) -> str:
    return hmac.new(pepper.encode(), token.encode(), hashlib.sha256).hexdigest()[:32]


def submit(
    db: Session, *, lat: float, lon: float, category: str, reporter: str, now: datetime
) -> None:
    cell_lat, cell_lon = snap_cell(lat, lon)
    db.add(
        PlaceReport(
            cell_lat=cell_lat,
            cell_lon=cell_lon,
            category=category,
            reporter_hash=reporter,
            created_at=now,
        )
    )
    db.commit()


def recent_from(db: Session, reporter: str, since: datetime) -> int:
    return (
        db.scalar(
            select(func.count())
            .select_from(PlaceReport)
            .where(PlaceReport.reporter_hash == reporter, PlaceReport.created_at >= since)
        )
        or 0
    )


def published_cells(
    db: Session,
    bbox: tuple[float, float, float, float],
    now: datetime,
    *,
    min_reports: int,
    min_devices: int,
    ttl_days: int,
    half_life_days: float,
) -> list[ReportCell]:
    south, west, north, east = bbox
    rows = db.execute(
        select(
            PlaceReport.cell_lat,
            PlaceReport.cell_lon,
            PlaceReport.reporter_hash,
            PlaceReport.created_at,
        ).where(
            PlaceReport.created_at >= now - timedelta(days=ttl_days),
            PlaceReport.cell_lat.between(south, north),
            PlaceReport.cell_lon.between(west, east),
        )
    ).all()
    by_cell: dict[LatLon, list[tuple[str, datetime]]] = defaultdict(list)
    for lat, lon, reporter, created in rows:
        by_cell[(lat, lon)].append((reporter, _aware(created)))
    cells = []
    for (lat, lon), reports in by_cell.items():
        reporters = {r for r, _ in reports}
        if not is_publishable(len(reports), len(reporters), min_reports, min_devices):
            continue
        weight = sum(
            0.5 ** ((now - created).total_seconds() / 86400 / half_life_days)
            for _, created in reports
        )
        cells.append(ReportCell(lat, lon, round(weight, 3), len(reports)))
    return cells


def _aware(when: datetime) -> datetime:
    return when if when.tzinfo else when.replace(tzinfo=UTC)
