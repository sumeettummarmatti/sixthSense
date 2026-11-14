"""Routes API (P4-W1-demo-safe-routes).

Lives in Insight so a route request carries no user identity (rule 4) and so place reports never
meet account data (rule 6). Start and destination are used for one response and never stored;
they are not logged either (the PII filter would scrub them, but we don't rely on it).
"""

import logging
import time
from datetime import UTC, datetime, timedelta
from functools import lru_cache
from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session

from app.core.config import Settings, get_settings
from app.core.db import get_db
from app.routing import reports as report_store
from app.routing.area import Area, load_area
from app.routing.geo import LatLon
from app.routing.providers import (
    OsrmProvider,
    Route,
    RouteProvider,
    RoutingUnavailable,
    ValhallaProvider,
    candidate_routes,
)
from app.routing.schemas import AreaOut, ReportCellOut, ReportIn, RouteOut, RoutesOut
from app.routing.scoring import TimeBand, assess, band_for, compare, describe, rank

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/routes", tags=["routing"])

INSIGHT_DIR = Path(__file__).resolve().parents[2]
DEMO_PAGE = Path(__file__).resolve().parent / "static" / "demo.html"
OUTSIDE_PAD_M = 1500  # start and destination may sit a little outside the data area
ROUTE_CACHE_SECONDS = 600  # the same two points give the same ways; only the scoring changes
ROUTE_CACHE_SIZE = 256

SettingsDep = Annotated[Settings, Depends(get_settings)]
DbDep = Annotated[Session, Depends(get_db)]


@lru_cache
def _area(path: str) -> Area:
    return load_area(path if Path(path).is_absolute() else INSIGHT_DIR / path)


def get_area(settings: SettingsDep) -> Area:
    return _area(settings.routes_area_file)


@lru_cache
def _provider(kind: str, base_url: str) -> RouteProvider:
    return ValhallaProvider(base_url) if kind == "valhalla" else OsrmProvider(base_url)


def get_provider(settings: SettingsDep) -> RouteProvider:
    if settings.routing_provider == "valhalla":
        return _provider("valhalla", settings.valhalla_base_url)
    return _provider("osrm", settings.osrm_base_url)


AreaDep = Annotated[Area, Depends(get_area)]
ProviderDep = Annotated[RouteProvider, Depends(get_provider)]

_route_cache: dict[tuple, tuple[float, list[Route]]] = {}


def _candidates(provider: RouteProvider, start: LatLon, end: LatLon) -> list[Route]:
    key = (id(provider), round(start[0], 5), round(start[1], 5), round(end[0], 5), round(end[1], 5))
    now = time.monotonic()
    hit = _route_cache.get(key)
    if hit and now - hit[0] < ROUTE_CACHE_SECONDS:
        return hit[1]
    routes = candidate_routes(provider, start, end)
    if len(_route_cache) >= ROUTE_CACHE_SIZE:
        _route_cache.pop(next(iter(_route_cache)))
    _route_cache[key] = (now, routes)
    return routes


def _point(value: str, name: str) -> LatLon:
    try:
        lat, lon = (float(part) for part in value.split(","))
    except ValueError:
        raise HTTPException(422, f"{name} must be 'lat,lon'") from None
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        raise HTTPException(422, f"{name} is not a valid coordinate")
    return lat, lon


def _band(at: str | None) -> TimeBand:
    if not at:
        return band_for(datetime.now(UTC))
    if at in {band.value for band in TimeBand}:
        return TimeBand(at)
    try:
        when = datetime.fromisoformat(at)
    except ValueError:
        raise HTTPException(422, "at must be day, evening, night or an ISO datetime") from None
    return band_for(when if when.tzinfo else when.replace(tzinfo=UTC))


def _published(db: Session, area: Area, settings: Settings, now: datetime):
    return report_store.published_cells(
        db,
        area.bbox,
        now,
        min_reports=settings.publish_min_reports,
        min_devices=settings.publish_min_devices,
        ttl_days=settings.report_ttl_days,
        half_life_days=settings.report_half_life_days,
    )


@router.get("", response_model=RoutesOut, summary="Walking routes between two points, ranked")
def plan(
    area: AreaDep,
    provider: ProviderDep,
    db: DbDep,
    settings: SettingsDep,
    from_: Annotated[str, Query(alias="from", description="lat,lon")],
    to: Annotated[str, Query(description="lat,lon")],
    at: Annotated[
        str | None, Query(description="day | evening | night | ISO datetime (default: now)")
    ] = None,
) -> RoutesOut:
    start, end = _point(from_, "from"), _point(to, "to")
    if not (area.contains(start, OUTSIDE_PAD_M) and area.contains(end, OUTSIDE_PAD_M)):
        raise HTTPException(422, "outside_area")
    band = _band(at)
    try:
        routes = _candidates(provider, start, end)
    except RoutingUnavailable as error:
        logger.warning("routing engine unavailable: %s", error)
        raise HTTPException(503, "routing_unavailable") from None
    if not routes:
        raise HTTPException(404, "no_route")

    cells = _published(db, area, settings, datetime.now(UTC))
    items = [assess(r.points, r.distance_m, r.duration_s, area, band, cells) for r in routes]
    shortest, recommended = rank(
        items, max_ratio=settings.routes_max_detour_ratio, max_extra_m=settings.routes_max_detour_m
    )
    base = items[shortest]
    out = []
    for i, a in enumerate(items):
        kind = "recommended" if i == recommended else "shortest" if i == shortest else "alternative"
        out.append(
            RouteOut(
                kind=kind,
                points=a.points,
                distance_m=round(a.distance_m),
                duration_s=round(a.duration_s),
                extra_m=round(a.distance_m - base.distance_m),
                extra_s=round(a.duration_s - base.duration_s),
                score=round(a.score, 3),
                support=a.support,
                concern=a.concern,
                coverage=a.coverage,
                evidence=a.evidence,
                counts=a.counts,
                facts=describe(a),
                why=compare(a, base) if i == recommended else [],
            )
        )
    return RoutesOut(
        area=area.name, time_band=band, shortest=shortest, recommended=recommended, routes=out
    )


@router.post("/reports", status_code=202, summary="Anonymous report about a place")
def report(body: ReportIn, area: AreaDep, db: DbDep, settings: SettingsDep) -> dict[str, str]:
    if not area.contains((body.lat, body.lon)):
        raise HTTPException(422, "outside_area")
    now = datetime.now(UTC)
    reporter = report_store.reporter_hash(body.reporter, settings.report_pepper)
    if (
        report_store.recent_from(db, reporter, now - timedelta(hours=1))
        >= settings.reports_per_hour
    ):
        raise HTTPException(429, "too_many_reports")
    report_store.submit(
        db, lat=body.lat, lon=body.lon, category=body.category, reporter=reporter, now=now
    )
    logger.info("place report accepted category=%s", body.category)
    return {"status": "accepted"}


@router.get("/area", response_model=AreaOut, summary="The area we have data for")
def area_info(area: AreaDep, db: DbDep, settings: SettingsDep) -> AreaOut:
    cells = _published(db, area, settings, datetime.now(UTC))
    return AreaOut(
        name=area.name,
        label=area.label,
        bbox=area.bbox,
        sources=area.sources,
        counts=area.counts(),
        published_cells=[
            ReportCellOut(lat=c.lat, lon=c.lon, count=c.count, weight=c.weight) for c in cells
        ],
        publish_min_reports=settings.publish_min_reports,
        publish_min_devices=settings.publish_min_devices,
        demo=settings.env == "dev",
    )


@router.get("/demo", include_in_schema=False)
def demo_page(settings: SettingsDep) -> FileResponse:
    if not settings.routes_demo_page:
        raise HTTPException(404)
    return FileResponse(DEMO_PAGE, media_type="text/html")
