"""Scores candidate walking routes by what is around them, for one time of day.

A route is a list of points. We walk it in 50 m steps and count, once each, the streetlights,
open places, bus stops, stations, police stations and hospitals within reach of any step. Those
counts per kilometre, with time-of-day weights, give a 0..1 "support" score; published report
cells (reports.py) reduce it. Nothing here says a street is safe (rule 5): a route with good
support and no reports is labelled "Insufficient data", because that is what we have.
"""

import math
from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum
from zoneinfo import ZoneInfo

from app.risk.labels import RiskLabel
from app.routing.area import OPEN_PLACE_KINDS, Area
from app.routing.geo import LatLon, haversine_m, sample_along

STEP_M = 50.0
GROUPS = ("lamp", "open", "bus_stop", "station", "police", "hospital")
RADIUS_M = {"lamp": 30, "open": 60, "bus_stop": 100, "station": 200, "police": 300, "hospital": 200}
# Density per km at which a group counts as well present (presence 0.63). Returns diminish above
# it, so a street with three times the target still edges one at the target, but one mall can't win.
TARGET_PER_KM = {
    "lamp": 40,
    "open": 20,
    "bus_stop": 3,
    "station": 0.5,
    "police": 0.3,
    "hospital": 0.5,
}
CONCERN_RADIUS_M = 60
CONCERN_FULL_PER_KM = 3.0  # this much weighted, published report evidence per km = full concern
CONCERN_PENALTY = 0.7  # a fully concerning route keeps 30% of its support score
MIN_COVERAGE = 0.5  # below this share of steps inside the area we only have "Insufficient data"
MIN_GAIN = 0.05  # don't suggest a detour for a score difference nobody would notice


class TimeBand(StrEnum):
    DAY = "day"
    EVENING = "evening"
    NIGHT = "night"


# Weights sum to 1 per band. Daylight makes lamps irrelevant; at night they matter most and only
# places still open count as "open".
WEIGHTS: dict[TimeBand, dict[str, float]] = {
    TimeBand.DAY: {
        "lamp": 0.0,
        "open": 0.40,
        "bus_stop": 0.25,
        "station": 0.15,
        "police": 0.10,
        "hospital": 0.10,
    },
    TimeBand.EVENING: {
        "lamp": 0.35,
        "open": 0.30,
        "bus_stop": 0.15,
        "station": 0.10,
        "police": 0.05,
        "hospital": 0.05,
    },
    TimeBand.NIGHT: {
        "lamp": 0.45,
        "open": 0.25,
        "bus_stop": 0.10,
        "station": 0.05,
        "police": 0.10,
        "hospital": 0.05,
    },
}


def band_for(when: datetime, tz: str = "Asia/Kolkata") -> TimeBand:
    hour = when.astimezone(ZoneInfo(tz)).hour if when.tzinfo else when.hour
    if 6 <= hour < 18:
        return TimeBand.DAY
    if 18 <= hour < 22:
        return TimeBand.EVENING
    return TimeBand.NIGHT


@dataclass(frozen=True)
class ReportCell:
    lat: float
    lon: float
    weight: float  # decayed evidence, roughly "recent reports"
    count: int


@dataclass
class Assessment:
    points: list[LatLon]
    distance_m: float
    duration_s: float
    band: TimeBand
    counts: dict[str, int] = field(default_factory=dict)
    support: float = 0.0
    concern: float = 0.0
    coverage: float = 1.0
    report_cells: int = 0

    @property
    def score(self) -> float:
        return self.support * (1 - CONCERN_PENALTY * self.concern)

    @property
    def evidence(self) -> RiskLabel:
        if self.concern >= 0.5:
            return RiskLabel.STRONG_EVIDENCE
        if self.concern > 0:
            return RiskLabel.SOME_REPORTS
        return RiskLabel.INSUFFICIENT_DATA


def _group_of(kind: str) -> str | None:
    if kind in OPEN_PLACE_KINDS:
        return "open"
    return kind if kind in GROUPS else None


def assess(
    points: Sequence[LatLon],
    distance_m: float,
    duration_s: float,
    area: Area,
    band: TimeBand,
    cells: Sequence[ReportCell] = (),
) -> Assessment:
    steps = sample_along(points, STEP_M)
    km = max(distance_m, 1.0) / 1000
    seen: dict[str, set[int]] = {group: set() for group in GROUPS}
    seen_cells: dict[tuple[float, float], float] = {}
    inside = 0
    cell_index = {(c.lat, c.lon): c for c in cells}
    for step in steps:
        if area.contains(step):
            inside += 1
        for kind, index in area.index.items():
            group = _group_of(kind)
            if group is None:
                continue
            for feature in index.within(step, RADIUS_M[group]):
                if group == "open" and band is TimeBand.NIGHT and not feature.late:
                    continue
                seen[group].add(feature.id)
        for key, cell in cell_index.items():
            if key not in seen_cells and haversine_m(step, key) <= CONCERN_RADIUS_M:
                seen_cells[key] = cell.weight

    counts = {group: len(ids) for group, ids in seen.items()}
    weights = WEIGHTS[band]
    support = sum(
        weights[group] * (1 - math.exp(-(counts[group] / km) / TARGET_PER_KM[group]))
        for group in GROUPS
    )
    concern = min(1.0, (sum(seen_cells.values()) / km) / CONCERN_FULL_PER_KM)
    return Assessment(
        points=list(points),
        distance_m=distance_m,
        duration_s=duration_s,
        band=band,
        counts=counts,
        support=round(support, 4),
        concern=round(concern, 4),
        coverage=round(inside / max(len(steps), 1), 3),
        report_cells=len(seen_cells),
    )


def rank(
    items: Sequence[Assessment], *, max_ratio: float, max_extra_m: float, min_gain: float = MIN_GAIN
) -> tuple[int, int]:
    """(shortest index, recommended index). The recommendation may be the shortest route."""
    shortest = min(range(len(items)), key=lambda i: items[i].distance_m)
    base = items[shortest].distance_m
    limit = min(base * max_ratio, base + max_extra_m)
    eligible = [
        i for i, a in enumerate(items) if a.distance_m <= limit and a.coverage >= MIN_COVERAGE
    ]
    if not eligible:
        return shortest, shortest
    best = max(eligible, key=lambda i: (items[i].score, -items[i].distance_m))
    if items[best].score - items[shortest].score < min_gain:
        return shortest, shortest
    return shortest, best


def _n(count: int, word: str) -> str:
    """'1 streetlight', '6 streetlights'."""
    return f"{count} {word}" if count == 1 else f"{count} {word}s"


def describe(a: Assessment) -> list[str]:
    """Plain facts about one route. Never a safety claim."""
    out = []
    if a.band is not TimeBand.DAY:
        out.append(_n(a.counts["lamp"], "streetlight"))
    late = " late" if a.band is TimeBand.NIGHT else ""
    out.append(f"{_n(a.counts['open'], 'place')} open{late}")
    if a.counts["bus_stop"]:
        out.append(_n(a.counts["bus_stop"], "bus stop"))
    if a.counts["station"]:
        out.append("metro or rail station on the way")
    if a.counts["police"]:
        out.append("police station nearby")
    if a.counts["hospital"]:
        out.append("hospital nearby")
    if a.report_cells:
        plural = "s" if a.report_cells != 1 else ""
        out.append(f"{a.report_cells} spot{plural} with published reports of concern")
    if a.coverage < MIN_COVERAGE:
        out.append("mostly outside the area we have data for")
    return out


def compare(recommended: Assessment, shortest: Assessment) -> list[str]:
    """Why the recommended route, against the shortest one."""
    if recommended is shortest:
        return ["shortest route"]
    out = []
    extra_min = round((recommended.duration_s - shortest.duration_s) / 60)
    out.append(f"+{extra_min} min" if extra_min > 0 else "about the same time")
    if recommended.band is not TimeBand.DAY:
        out.append(f"{_n(recommended.counts['lamp'], 'streetlight')} vs {shortest.counts['lamp']}")
    out.append(f"{recommended.counts['open']} open places vs {shortest.counts['open']}")
    if recommended.report_cells < shortest.report_cells:
        out.append("avoids spots with published reports of concern")
    return out
