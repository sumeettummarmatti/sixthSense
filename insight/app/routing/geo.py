"""Geometry helpers for route scoring. Pure functions; metres and WGS-84 degrees.

Precision here is "good enough to count lamps within 30 m", not surveying: the Earth is a sphere
and the grid index uses a flat approximation for its search window.
"""

import math
from collections import defaultdict
from collections.abc import Sequence
from typing import Any

LatLon = tuple[float, float]
EARTH_RADIUS_M = 6_371_000.0
_M_PER_DEG_LAT = 111_320.0


def haversine_m(a: LatLon, b: LatLon) -> float:
    lat1, lon1, lat2, lon2 = map(math.radians, (*a, *b))
    h = math.sin((lat2 - lat1) / 2) ** 2
    h += math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(min(1.0, h)))


def bearing_deg(a: LatLon, b: LatLon) -> float:
    lat1, lon1, lat2, lon2 = map(math.radians, (*a, *b))
    dlon = lon2 - lon1
    x = math.sin(dlon) * math.cos(lat2)
    y = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dlon)
    return math.degrees(math.atan2(x, y)) % 360


def destination(start: LatLon, bearing: float, distance_m: float) -> LatLon:
    """The point `distance_m` away from `start` in direction `bearing` (degrees from north)."""
    lat1, lon1 = map(math.radians, start)
    theta, d = math.radians(bearing), distance_m / EARTH_RADIUS_M
    lat2 = math.asin(math.sin(lat1) * math.cos(d) + math.cos(lat1) * math.sin(d) * math.cos(theta))
    lon2 = lon1 + math.atan2(
        math.sin(theta) * math.sin(d) * math.cos(lat1),
        math.cos(d) - math.sin(lat1) * math.sin(lat2),
    )
    return math.degrees(lat2), (math.degrees(lon2) + 540) % 360 - 180


def length_m(points: Sequence[LatLon]) -> float:
    return sum(haversine_m(points[i], points[i + 1]) for i in range(len(points) - 1))


def sample_along(points: Sequence[LatLon], step_m: float) -> list[LatLon]:
    """Points every `step_m` along the line, always including both ends."""
    if len(points) < 2:
        return list(points)
    out = [points[0]]
    carry = 0.0  # distance walked since the last emitted sample
    for i in range(len(points) - 1):
        a, b = points[i], points[i + 1]
        seg = haversine_m(a, b)
        if seg == 0:
            continue
        pos = step_m - carry
        while pos <= seg:
            f = pos / seg
            out.append((a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f))
            pos += step_m
        carry = seg - (pos - step_m)
    if out[-1] != points[-1]:
        out.append(points[-1])
    return out


def point_at_fraction(points: Sequence[LatLon], fraction: float) -> tuple[LatLon, float]:
    """The point `fraction` (0..1) of the way along the line, and the line's bearing there."""
    if len(points) < 2:
        return points[0], 0.0
    target = length_m(points) * min(max(fraction, 0.0), 1.0)
    walked = 0.0
    for i in range(len(points) - 1):
        a, b = points[i], points[i + 1]
        seg = haversine_m(a, b)
        if seg > 0 and walked + seg >= target:
            f = (target - walked) / seg
            return (a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f), bearing_deg(a, b)
        walked += seg
    return points[-1], bearing_deg(points[-2], points[-1])


class GridIndex:
    """Buckets points into ~cell_deg squares so "what is within r metres?" touches few points."""

    def __init__(self, cell_deg: float = 0.001) -> None:
        self.cell_deg = cell_deg
        self._cells: dict[tuple[int, int], list[tuple[LatLon, Any]]] = defaultdict(list)
        self.count = 0

    def _key(self, lat: float, lon: float) -> tuple[int, int]:
        return math.floor(lat / self.cell_deg), math.floor(lon / self.cell_deg)

    def add(self, point: LatLon, item: Any) -> None:
        self._cells[self._key(*point)].append((point, item))
        self.count += 1

    def within(self, point: LatLon, radius_m: float) -> list[Any]:
        lat, lon = point
        dlat = radius_m / _M_PER_DEG_LAT
        dlon = radius_m / (_M_PER_DEG_LAT * max(math.cos(math.radians(lat)), 0.01))
        (i0, j0), (i1, j1) = self._key(lat - dlat, lon - dlon), self._key(lat + dlat, lon + dlon)
        found = []
        for i in range(i0, i1 + 1):
            for j in range(j0, j1 + 1):
                for p, item in self._cells.get((i, j), ()):
                    if haversine_m(point, p) <= radius_m:
                        found.append(item)
        return found


def overlap(a: Sequence[LatLon], b: Sequence[LatLon], cell_deg: float = 0.00025) -> float:
    """Share of ~25 m map cells two lines have in common (Jaccard). 1.0 means the same way."""

    def cells(points: Sequence[LatLon]) -> set[tuple[int, int]]:
        return {
            (math.floor(p[0] / cell_deg), math.floor(p[1] / cell_deg))
            for p in sample_along(points, 20)
        }

    ca, cb = cells(a), cells(b)
    union = ca | cb
    return len(ca & cb) / len(union) if union else 1.0
