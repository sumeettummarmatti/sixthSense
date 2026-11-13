from datetime import UTC, datetime, timedelta

import httpx
import pytest

from app.routing import reports as report_store
from app.routing.providers import (
    OsrmProvider,
    RoutingUnavailable,
    candidate_routes,
    decode_polyline,
)
from tests.conftest import END, START

FROM_TO = f"from={START[0]},{START[1]}&to={END[0]},{END[1]}"


def test_routes_night_recommends_the_lit_street(client) -> None:
    resp = client.get(f"/routes?{FROM_TO}&at=night")
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["time_band"] == "night" and data["recommended"] != data["shortest"]
    rec = data["routes"][data["recommended"]]
    assert rec["kind"] == "recommended" and rec["extra_m"] > 0
    assert any("streetlights vs 0" in w for w in rec["why"])
    assert all("safe" not in r["evidence"].lower() for r in data["routes"])


def test_routes_validation(client) -> None:
    assert client.get(f"/routes?from=12.97&to={END[0]},{END[1]}").status_code == 422
    far = client.get(f"/routes?from=13.2,77.9&to={END[0]},{END[1]}")
    assert far.status_code == 422 and far.json()["detail"] == "outside_area"
    assert client.get(f"/routes?{FROM_TO}&at=midnight").status_code == 422


def test_routes_when_engine_is_down(client, provider) -> None:
    provider.fail = True
    resp = client.get(f"/routes?{FROM_TO}")
    assert resp.status_code == 503 and resp.json()["detail"] == "routing_unavailable"


def test_candidates_are_cached_per_pair(client, provider) -> None:
    client.get(f"/routes?{FROM_TO}&at=day")
    calls = len(provider.calls)
    client.get(f"/routes?{FROM_TO}&at=night")
    assert len(provider.calls) == calls  # same ways, only the scoring changed


def test_reports_publish_only_at_threshold(client) -> None:
    spot = {"lat": 12.9700, "lon": 77.6400, "category": "dark"}
    first = client.post("/routes/reports", json={**spot, "reporter": "device-one-token"})
    assert first.status_code == 202
    assert client.get("/routes/area").json()["published_cells"] == []  # 1 of 2 reporters
    before = client.get(f"/routes?{FROM_TO}&at=night").json()
    assert before["routes"][before["recommended"]]["concern"] == 0

    second = client.post("/routes/reports", json={**spot, "reporter": "device-two-token"})
    assert second.status_code == 202
    area = client.get("/routes/area").json()
    assert len(area["published_cells"]) == 1 and area["published_cells"][0]["count"] == 2
    after = client.get(f"/routes?{FROM_TO}&at=night").json()
    lit = next(r for r in after["routes"] if r["counts"]["lamp"] > 0)
    assert lit["concern"] > 0 and lit["evidence"] != "Insufficient data"


def test_reports_rate_limit_and_validation(client) -> None:
    spot = {"lat": 12.9700, "lon": 77.6400, "category": "other", "reporter": "same-device-token"}
    codes = [client.post("/routes/reports", json=spot).status_code for _ in range(4)]
    assert codes == [202, 202, 202, 429]
    outside = {**spot, "lat": 13.2, "reporter": "another-device-token"}
    assert client.post("/routes/reports", json=outside).status_code == 422
    assert client.post("/routes/reports", json={**spot, "category": "people"}).status_code == 422


def test_reports_store_only_a_cell_and_a_hash(client, db) -> None:
    body = {"lat": 12.970123, "lon": 77.640456, "category": "dark", "reporter": "device-one-token"}
    client.post("/routes/reports", json=body)
    row = db.query(report_store.PlaceReport).one()
    assert (row.cell_lat, row.cell_lon) == report_store.snap_cell(12.970123, 77.640456)
    assert row.cell_lat != 12.970123 and "device-one-token" not in row.reporter_hash
    assert {c.name for c in row.__table__.columns} == {
        "id",
        "cell_lat",
        "cell_lon",
        "category",
        "reporter_hash",
        "created_at",
    }


def test_evidence_fades_and_expires(db) -> None:
    now = datetime.now(UTC)
    kwargs = {"min_reports": 1, "min_devices": 1, "ttl_days": 90, "half_life_days": 30}
    bbox = (12.9, 77.6, 13.0, 77.7)
    report_store.submit(db, lat=12.97, lon=77.64, category="dark", reporter="a", now=now)
    fresh = report_store.published_cells(db, bbox, now, **kwargs)[0].weight
    old = report_store.published_cells(db, bbox, now + timedelta(days=30), **kwargs)[0].weight
    assert abs(fresh - 1.0) < 0.01 and abs(old - 0.5) < 0.01
    assert report_store.published_cells(db, bbox, now + timedelta(days=91), **kwargs) == []


def test_demo_page_never_claims_safety(client) -> None:
    resp = client.get("/routes/demo")
    assert resp.status_code == 200 and "SixthSense routes" in resp.text
    text = resp.text.lower().replace("unsafe", "").replace('"safe"', "")
    assert "safe" not in text  # the only mention is the note that we never say it
    assert "#2f7d78" not in text and "#00ff00" not in text  # no green, not even the theme's teal


def test_candidate_routes_dedupe_and_cap(provider) -> None:
    routes = candidate_routes(provider, START, END)
    assert len(routes) == 2  # the dark direct way plus one lit alternative, duplicates dropped
    assert routes[0].distance_m < routes[1].distance_m and routes[1].via is not None
    provider.lit_extra = 1.7
    assert len(candidate_routes(provider, START, END)) == 1  # beyond 1.6x is never offered


def test_osrm_provider_parsing() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path.startswith("/route/v1/foot/77.635000,12.970600;")
        if "77.999" in str(request.url):
            return httpx.Response(400, json={"code": "NoRoute"})
        return httpx.Response(
            200,
            json={
                "code": "Ok",
                "routes": [
                    {
                        "distance": 1234.5,
                        "duration": 950.0,
                        "geometry": {
                            "type": "LineString",
                            "coordinates": [[77.635, 12.970], [77.645, 12.970]],
                        },
                    }
                ],
            },
        )

    transport = httpx.MockTransport(handler)
    provider = OsrmProvider("http://osrm.test", client=httpx.Client(transport=transport))
    [route] = provider.routes([START, END])
    assert route.points == [(12.970, 77.635), (12.970, 77.645)] and route.distance_m == 1234.5
    assert provider.routes([START, (12.97, 77.999)]) == []

    def down(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refused")

    broken = OsrmProvider(
        "http://osrm.test", client=httpx.Client(transport=httpx.MockTransport(down))
    )
    with pytest.raises(RoutingUnavailable):
        broken.routes([START, END])


def test_decode_polyline() -> None:
    assert decode_polyline("_p~iF~ps|U_ulLnnqC_mqNvxq`@", precision=5) == [
        (38.5, -120.2),
        (40.7, -120.95),
        (43.252, -126.453),
    ]
