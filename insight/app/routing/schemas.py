from typing import Literal

from pydantic import BaseModel, Field

from app.risk.labels import RiskLabel
from app.routing.scoring import TimeBand

Category = Literal["dark", "no_footpath", "harassment", "unsafe_crossing", "other"]


class RouteOut(BaseModel):
    kind: Literal["recommended", "shortest", "alternative"]
    points: list[tuple[float, float]]  # [lat, lon] pairs
    distance_m: int
    duration_s: int
    extra_m: int  # against the shortest route
    extra_s: int
    score: float  # 0..1, higher = more support around it for this time of day
    support: float
    concern: float  # 0..1 from published reports only
    coverage: float  # share of the route inside the area we have data for
    evidence: RiskLabel
    counts: dict[str, int]
    facts: list[str]  # plain observations, e.g. "38 streetlights"
    why: list[str]  # for the recommended route: against the shortest


class RoutesOut(BaseModel):
    area: str
    time_band: TimeBand
    shortest: int  # index into routes
    recommended: int
    routes: list[RouteOut]
    note: str = "Ranked by what is around each route at this hour. No route is labelled safe."


class ReportIn(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)
    category: Category
    reporter: str = Field(min_length=8, max_length=128)  # opaque token; only its HMAC is kept


class ReportCellOut(BaseModel):
    lat: float
    lon: float
    count: int
    weight: float


class AreaOut(BaseModel):
    name: str
    label: str
    bbox: tuple[float, float, float, float]  # south, west, north, east
    sources: list[str]
    counts: dict[str, int]
    published_cells: list[ReportCellOut]  # at or above the publish threshold only
    publish_min_reports: int
    publish_min_devices: int
    demo: bool  # dev server: the demo page may simulate several reporters
