"""Walking routes from a routing engine, plus home-made alternatives.

Routers usually return one or two routes between two points. To give the scorer a real choice we
also route through "via" points pushed ~250 m to either side of the shortest route at a third,
half and two thirds of the way, then drop near-duplicates. The same code works with the public
OSRM server (no key; the dev default) and a local Valhalla (routing-engine/, for the demo laptop).
Start and destination go to the router and are never stored or logged here (rule 2).
"""

import logging
from collections.abc import Sequence
from dataclasses import dataclass, replace
from typing import Protocol

import httpx

from app.routing.geo import LatLon, destination, overlap, point_at_fraction

DUPLICATE_OVERLAP = 0.75

# httpx logs every request URL at INFO, and ours carry the start and destination. Keep quiet.
logging.getLogger("httpx").setLevel(logging.WARNING)


class RoutingUnavailable(Exception):
    """The routing engine could not be reached or answered with an error."""


@dataclass(frozen=True)
class Route:
    points: list[LatLon]
    distance_m: float
    duration_s: float
    via: LatLon | None = None  # the side point this alternative was forced through, if any


class RouteProvider(Protocol):
    def routes(self, waypoints: Sequence[LatLon]) -> list[Route]:
        """Walking routes through `waypoints` in order; [] when there is no way."""


def _client() -> httpx.Client:
    return httpx.Client(timeout=httpx.Timeout(8, connect=8))


class OsrmProvider:
    """Any OSRM-compatible HTTP API: the FOSSGIS foot router, or a local foot osrm-backend."""

    def __init__(self, base_url: str, client: httpx.Client | None = None, profile: str = "foot"):
        self.base_url = base_url.rstrip("/")
        self.profile = profile
        self.client = client or _client()

    def routes(self, waypoints: Sequence[LatLon]) -> list[Route]:
        coords = ";".join(f"{lon:.6f},{lat:.6f}" for lat, lon in waypoints)
        params = {
            "overview": "full",
            "geometries": "geojson",
            "steps": "false",
            "alternatives": "3" if len(waypoints) == 2 else "false",
        }
        try:
            resp = self.client.get(
                f"{self.base_url}/route/v1/{self.profile}/{coords}", params=params
            )
        except httpx.HTTPError as error:
            raise RoutingUnavailable(type(error).__name__) from error
        if resp.status_code == 400:  # NoRoute / NoSegment: nothing walkable there
            return []
        if resp.status_code != 200:
            raise RoutingUnavailable(f"osrm http {resp.status_code}")
        data = resp.json()
        if data.get("code") != "Ok":
            return []
        return [
            Route(
                points=[(lat, lon) for lon, lat in r["geometry"]["coordinates"]],
                distance_m=float(r["distance"]),
                duration_s=float(r["duration"]),
            )
            for r in data["routes"]
        ]


class ValhallaProvider:
    """A local Valhalla (routing-engine/docker-compose.yml), pedestrian costing."""

    def __init__(self, base_url: str, client: httpx.Client | None = None):
        self.base_url = base_url.rstrip("/")
        self.client = client or _client()

    def routes(self, waypoints: Sequence[LatLon]) -> list[Route]:
        body: dict = {
            "locations": [{"lat": lat, "lon": lon} for lat, lon in waypoints],
            "costing": "pedestrian",
            "units": "kilometers",
        }
        if len(waypoints) == 2:
            body["alternates"] = 2
        try:
            resp = self.client.post(f"{self.base_url}/route", json=body)
        except httpx.HTTPError as error:
            raise RoutingUnavailable(type(error).__name__) from error
        if resp.status_code == 400:
            return []
        if resp.status_code != 200:
            raise RoutingUnavailable(f"valhalla http {resp.status_code}")
        data = resp.json()
        trips = [data["trip"]] + [alt["trip"] for alt in data.get("alternates", [])]
        return [self._route(trip) for trip in trips]

    @staticmethod
    def _route(trip: dict) -> Route:
        points = [p for leg in trip["legs"] for p in decode_polyline(leg["shape"])]
        summary = trip["summary"]
        return Route(points, float(summary["length"]) * 1000, float(summary["time"]))


def decode_polyline(encoded: str, precision: int = 6) -> list[LatLon]:
    """Google encoded polyline; Valhalla uses 6 decimals."""
    factor = 10**precision
    out: list[LatLon] = []
    index = lat = lon = 0
    while index < len(encoded):
        deltas = []
        for _ in range(2):
            result = shift = 0
            while True:
                b = ord(encoded[index]) - 63
                index += 1
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20:
                    break
            deltas.append(~(result >> 1) if result & 1 else result >> 1)
        lat += deltas[0]
        lon += deltas[1]
        out.append((lat / factor, lon / factor))
    return out


def candidate_routes(
    provider: RouteProvider,
    start: LatLon,
    end: LatLon,
    *,
    fractions: Sequence[float] = (1 / 3, 1 / 2, 2 / 3),
    offsets_m: Sequence[float] = (250.0,),
    max_ratio: float = 1.6,
    max_routes: int = 6,
) -> list[Route]:
    """Distinct walking routes, shortest first. Empty when the router finds no way at all."""
    direct = provider.routes([start, end])
    if not direct:
        return []
    shortest = min(direct, key=lambda r: r.distance_m)
    found = list(direct)
    for fraction in fractions:
        point, bearing = point_at_fraction(shortest.points, fraction)
        for offset in offsets_m:
            for side in (90, -90):
                via = destination(point, bearing + side, offset)
                for route in provider.routes([start, via, end]):
                    found.append(replace(route, via=via))
    kept: list[Route] = []
    for route in sorted(found, key=lambda r: r.distance_m):
        if route.distance_m > shortest.distance_m * max_ratio:
            break
        if len(route.points) < 2:
            continue
        if any(overlap(route.points, k.points) >= DUPLICATE_OVERLAP for k in kept):
            continue
        kept.append(route)
        if len(kept) >= max_routes:
            break
    return kept
