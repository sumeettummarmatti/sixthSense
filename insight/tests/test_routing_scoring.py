from datetime import UTC, datetime

from app.risk.labels import RiskLabel
from app.routing.geo import destination, haversine_m, overlap, sample_along
from app.routing.scoring import (
    WEIGHTS,
    ReportCell,
    TimeBand,
    assess,
    band_for,
    compare,
    describe,
    rank,
)
from tests.conftest import DARK_LAT, LIT_LAT, route_via

RANK = {"max_ratio": 1.25, "max_extra_m": 600}


def both(area, band, cells=()):
    dark, lit = route_via(DARK_LAT), route_via(LIT_LAT, 1.08)
    return [assess(r.points, r.distance_m, r.duration_s, area, band, cells) for r in (dark, lit)]


def test_night_prefers_the_lit_street(area) -> None:
    items = both(area, TimeBand.NIGHT)
    assert items[1].counts["lamp"] > 30 and items[0].counts["lamp"] == 0
    assert rank(items, **RANK) == (0, 1)


def test_daylight_ignores_lamps_but_counts_open_places(area) -> None:
    assert WEIGHTS[TimeBand.DAY]["lamp"] == 0
    items = both(area, TimeBand.DAY)
    assert items[1].counts["lamp"] > 0
    assert items[1].support > items[0].support  # the food places still count by day
    assert "streetlights" not in " ".join(describe(items[1]))


def test_detour_cap_keeps_the_shortest(area) -> None:
    dark, far = route_via(DARK_LAT), route_via(LIT_LAT, 1.5)
    items = [
        assess(r.points, r.distance_m, r.duration_s, area, TimeBand.NIGHT) for r in (dark, far)
    ]
    assert rank(items, **RANK) == (0, 0)


def test_published_reports_pull_a_route_down(area) -> None:
    cells = [ReportCell(LIT_LAT, 77.6400, weight=4.0, count=5)]
    items = both(area, TimeBand.NIGHT, cells)
    assert items[1].concern > 0 and items[0].concern == 0
    assert items[1].evidence in (RiskLabel.SOME_REPORTS, RiskLabel.STRONG_EVIDENCE)
    assert items[1].score < items[1].support


def test_labels_never_say_safe(area) -> None:
    items = both(area, TimeBand.EVENING)
    text = " ".join(describe(items[1]) + compare(items[1], items[0]) + [items[0].evidence.value])
    assert "safe" not in text.lower()
    assert items[0].evidence is RiskLabel.INSUFFICIENT_DATA  # no reports is not "safe"


def test_compare_explains_the_recommendation(area) -> None:
    items = both(area, TimeBand.NIGHT)
    why = compare(items[1], items[0])
    assert why[0].startswith("+") or why[0] == "about the same time"
    assert any("streetlights vs 0" in w for w in why)
    assert compare(items[0], items[0]) == ["shortest route"]


def test_low_coverage_is_insufficient_and_not_recommended(area) -> None:
    far_away = [(13.10, 77.70), (13.11, 77.71)]
    a = assess(far_away, 1500, 1100, area, TimeBand.NIGHT)
    assert a.coverage == 0 and a.evidence is RiskLabel.INSUFFICIENT_DATA
    assert "outside the area" in " ".join(describe(a))


def test_time_bands() -> None:
    ist = "Asia/Kolkata"
    assert band_for(datetime(2026, 11, 13, 9, 30, tzinfo=UTC), ist) is TimeBand.DAY  # 15:00 IST
    assert band_for(datetime(2026, 11, 13, 14, 0, tzinfo=UTC), ist) is TimeBand.EVENING  # 19:30
    assert band_for(datetime(2026, 11, 13, 18, 0, tzinfo=UTC), ist) is TimeBand.NIGHT  # 23:30
    assert band_for(datetime(2026, 11, 13, 23, 0, tzinfo=UTC), ist) is TimeBand.NIGHT  # 04:30


def test_geo_helpers() -> None:
    a = (12.97, 77.64)
    b = destination(a, 90, 250)
    assert abs(haversine_m(a, b) - 250) < 0.5
    line = [a, destination(a, 0, 1000)]
    samples = sample_along(line, 50)
    assert len(samples) == 21 and samples[0] == a and samples[-1] == line[1]
    assert overlap(line, line) == 1.0
    assert overlap(line, [destination(a, 90, 300), destination(b, 0, 1000)]) == 0.0
