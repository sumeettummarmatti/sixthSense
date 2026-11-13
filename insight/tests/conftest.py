"""Fixtures for the routes tests: a synthetic area with one lit street and one dark street, a
fake routing engine that offers both, SQLite for reports. Nothing touches the network."""

from collections.abc import Iterator, Sequence

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.config import Settings, get_settings
from app.core.db import Base, get_db
from app.main import app
from app.routing import models  # noqa: F401  (registers the table on Base)
from app.routing.area import Area, build_area
from app.routing.geo import LatLon, haversine_m
from app.routing.providers import Route, RoutingUnavailable
from app.routing.router import _route_cache, get_area, get_provider

# Start and end sit between two parallel east-west streets ~130 m apart; every route forks to one.
START: LatLon = (12.9706, 77.6350)
END: LatLon = (12.9706, 77.6450)  # ~1.08 km due east
LIT_LAT = 12.9700  # lamps every 25 m, late-open places every 100 m
DARK_LAT = 12.9712  # nothing on it; the fake router's direct (shortest) answer


def street(lat: float, n: int = 12) -> list[LatLon]:
    return [(lat, START[1] + (END[1] - START[1]) * i / n) for i in range(n + 1)]


def route_via(lat: float, extra: float = 1.0) -> Route:
    """A route along `lat` from START to END; `extra` scales the reported distance."""
    points = [START, *street(lat)[1:-1], END]
    distance = sum(haversine_m(points[i], points[i + 1]) for i in range(len(points) - 1)) * extra
    return Route(points=points, distance_m=distance, duration_s=distance / 1.3)


def lamps_and_places(lat: float) -> list[tuple[str, float, float, bool]]:
    rows = []
    total = haversine_m((lat, START[1]), (lat, END[1]))
    for i in range(int(total // 25) + 1):
        lon = START[1] + (END[1] - START[1]) * (i * 25 / total)
        rows.append(("lamp", lat, lon, False))
        if i % 4 == 0:
            rows.append(("food", lat, lon, True))
    return rows


@pytest.fixture
def area() -> Area:
    return build_area(
        "testville",
        "Testville",
        (12.960, 77.625, 12.980, 77.655),
        ["synthetic"],
        lamps_and_places(LIT_LAT),
    )


class FakeProvider:
    """Direct route = the dark street (shortest). Any via point south of it = the lit street."""

    def __init__(self, lit_extra: float = 1.08):
        self.lit_extra = lit_extra
        self.calls: list[Sequence[LatLon]] = []
        self.fail = False

    def routes(self, waypoints: Sequence[LatLon]) -> list[Route]:
        if self.fail:
            raise RoutingUnavailable("down")
        self.calls.append(list(waypoints))
        if len(waypoints) == 2:
            return [route_via(DARK_LAT)]
        if waypoints[1][0] < DARK_LAT:
            return [route_via(LIT_LAT, self.lit_extra)]
        return []


@pytest.fixture
def provider() -> FakeProvider:
    return FakeProvider()


@pytest.fixture
def settings() -> Settings:
    return Settings(
        env="test",
        publish_min_reports=2,
        publish_min_devices=2,
        reports_per_hour=3,
        report_pepper="test-pepper",
    )


@pytest.fixture
def db() -> Iterator[Session]:
    engine = create_engine(
        "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool
    )
    Base.metadata.create_all(engine)
    with sessionmaker(bind=engine)() as session:
        yield session


@pytest.fixture
def client(
    area: Area, provider: FakeProvider, settings: Settings, db: Session
) -> Iterator[TestClient]:
    _route_cache.clear()
    app.dependency_overrides[get_area] = lambda: area
    app.dependency_overrides[get_provider] = lambda: provider
    app.dependency_overrides[get_settings] = lambda: settings
    app.dependency_overrides[get_db] = lambda: db
    try:
        yield TestClient(app)
    finally:
        app.dependency_overrides.clear()
