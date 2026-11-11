import uuid
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import inspect, select, update

from app.core.audit import AuditEvent
from app.journey import service
from app.journey.models import Journey
from app.journey.router import _now
from app.main import app

T0 = datetime(2026, 11, 11, 20, 0, tzinfo=UTC)


class Clock:
    def __init__(self) -> None:
        self.now = T0

    def advance(self, minutes: float) -> None:
        self.now += timedelta(minutes=minutes)


@pytest.fixture
def clock(client):
    clock = Clock()
    app.dependency_overrides[_now] = lambda: clock.now
    return clock


@pytest.fixture
def user(make_user):
    return make_user("walker@college.edu")


def start(client, user, **body) -> dict:
    resp = client.post("/journeys", json=body, headers=user["headers"])
    assert resp.status_code == 201, resp.text
    return resp.json()


def act(client, user, journey_id: str, action: str, json: dict | None = None):
    return client.post(f"/journeys/{journey_id}/{action}", json=json, headers=user["headers"])


def walk(client, user, journey_id: str, clock: Clock, minutes: float) -> None:
    """Let time pass while the phone sends a heartbeat every 5 minutes, like the real app."""
    while minutes > 0:
        step = min(5, minutes)
        clock.advance(step)
        minutes -= step
        act(client, user, journey_id, "heartbeat")


def current(client, user):
    return client.get("/journeys/current", headers=user["headers"])


def db_journey(db, journey_id: str) -> Journey:
    db.expire_all()
    return db.get(Journey, uuid.UUID(journey_id))


# --- auth and protocol ---------------------------------------------------------------------


@pytest.mark.parametrize(
    ("method", "path"),
    [
        ("get", "/journeys/protocol"),
        ("put", "/journeys/protocol"),
        ("post", "/journeys"),
        ("get", "/journeys/current"),
        ("post", f"/journeys/{uuid.uuid4()}/check-in"),
        ("post", f"/journeys/{uuid.uuid4()}/sos"),
    ],
)
def test_every_endpoint_requires_sign_in(client, method, path) -> None:
    assert getattr(client, method)(path).status_code == 401


def test_protocol_defaults_and_update(client, user) -> None:
    resp = client.get("/journeys/protocol", headers=user["headers"])
    assert resp.json() == {
        "check_in_interval_min": 15,
        "check_in_grace_min": 2,
        "prompt_timeout_min": 2,
        "contact_response_min": 5,
        "heartbeat_timeout_min": 10,
        "auto_112": False,
        "alert_contact_ids": None,
    }
    body = {**resp.json(), "check_in_interval_min": 30, "auto_112": True}
    assert client.put("/journeys/protocol", json=body, headers=user["headers"]).json() == body
    assert client.get("/journeys/protocol", headers=user["headers"]).json() == body


@pytest.mark.parametrize(
    "change",
    [{"check_in_interval_min": 0}, {"check_in_interval_min": 241}, {"prompt_timeout_min": 0}],
)
def test_protocol_ranges_enforced(client, user, change) -> None:
    resp = client.put("/journeys/protocol", json=change, headers=user["headers"])
    assert resp.status_code == 422


def test_protocol_alert_contacts_must_be_accepted_contacts(client, user, make_user) -> None:
    friend = make_user("friend@college.edu")
    invite = client.post(
        "/contacts/invites", json={"owner_label": "Priya"}, headers=user["headers"]
    ).json()
    pending_id = invite["contact_link_id"]
    resp = client.put(
        "/journeys/protocol", json={"alert_contact_ids": [pending_id]}, headers=user["headers"]
    )
    assert resp.status_code == 422  # not accepted yet
    client.post(
        "/contacts/invites/accept",
        json={"invite_token": invite["invite_token"]},
        headers=friend["headers"],
    )
    resp = client.put(
        "/journeys/protocol", json={"alert_contact_ids": [pending_id]}, headers=user["headers"]
    )
    assert resp.status_code == 200
    resp = client.put(
        "/journeys/protocol",
        json={"alert_contact_ids": [str(uuid.uuid4())]},
        headers=user["headers"],
    )
    assert resp.status_code == 422


# --- start and timers ----------------------------------------------------------------------


def test_start_copies_protocol_and_allows_interval_override(client, user, clock) -> None:
    client.put("/journeys/protocol", json={"check_in_interval_min": 20}, headers=user["headers"])
    journey = start(client, user)
    assert journey["state"] == "active"
    assert journey["timers"]["check_in_interval_min"] == 20
    assert journey["next_check_in_at"] == (T0 + timedelta(minutes=20)).isoformat().replace(
        "+00:00", "Z"
    )
    act(client, user, journey["id"], "end")
    assert start(client, user, check_in_interval_min=5)["timers"]["check_in_interval_min"] == 5


def test_protocol_change_does_not_affect_running_journey(client, user, clock) -> None:
    journey = start(client, user)
    client.put("/journeys/protocol", json={"check_in_interval_min": 60}, headers=user["headers"])
    assert current(client, user).json()["timers"]["check_in_interval_min"] == 15
    assert journey["timers"]["check_in_interval_min"] == 15


def test_only_one_open_journey(client, user, clock) -> None:
    start(client, user)
    resp = client.post("/journeys", json={}, headers=user["headers"])
    assert resp.status_code == 409
    assert resp.json()["detail"] == "journey_already_open"


def test_no_current_journey(client, user) -> None:
    resp = current(client, user)
    assert resp.status_code == 404
    assert resp.json()["detail"] == "no_open_journey"


def test_server_watchdog_steps_through_missed_check_in(client, user, clock) -> None:
    journey = start(client, user)
    for minutes, state in [(14, "active"), (1, "check_in_due"), (2, "private_prompt")]:
        walk(client, user, journey["id"], clock, minutes)
        assert current(client, user).json()["state"] == state
    walk(client, user, journey["id"], clock, 2)
    assert current(client, user).json()["state"] == "contact_alert"
    clock.advance(5)  # contacts didn't answer
    assert current(client, user).json()["state"] == "full_escalation"


def test_heartbeat_keeps_journey_alive_and_silence_alerts_contacts(client, user, clock, db) -> None:
    journey = start(client, user, check_in_interval_min=60)
    for _ in range(5):
        clock.advance(9)
        assert act(client, user, journey["id"], "heartbeat").json()["state"] == "active"
    assert db_journey(db, journey["id"]).last_heartbeat_at == clock.now
    clock.advance(10)
    assert current(client, user).json()["state"] == "contact_alert"


def test_check_in_resets_the_timer(client, user, clock) -> None:
    journey = start(client, user)
    walk(client, user, journey["id"], clock, 16)
    resp = act(client, user, journey["id"], "check-in", {"result": "ok"})
    assert resp.json()["state"] == "active"
    expected = clock.now + timedelta(minutes=15)
    assert resp.json()["next_check_in_at"] == expected.isoformat().replace("+00:00", "Z")


def test_prompt_endpoint(client, user, clock) -> None:
    journey = start(client, user)
    walk(client, user, journey["id"], clock, 15)
    assert act(client, user, journey["id"], "prompt").json()["state"] == "private_prompt"


# --- duress and SOS ------------------------------------------------------------------------


def test_duress_response_is_identical_to_real_pin(client, user, make_user, clock, db) -> None:
    other = make_user("other@college.edu")
    real, duress = start(client, user), start(client, other)
    for _ in range(4):
        clock.advance(4)
        act(client, user, real["id"], "heartbeat")
        act(client, other, duress["id"], "heartbeat")
    ok = act(client, user, real["id"], "check-in", {"result": "ok"})
    forced = act(client, other, duress["id"], "check-in", {"result": "duress"})
    assert ok.status_code == forced.status_code == 200
    strip = lambda body: {k: v for k, v in body.items() if k != "id"}  # noqa: E731
    assert strip(ok.json()) == strip(forced.json())
    assert ok.headers.keys() == forced.headers.keys()

    row = db_journey(db, duress["id"])
    assert row.state == "full_escalation" and row.covert
    assert current(client, other).json()["state"] == "active"
    actions = set(db.scalars(select(AuditEvent.action)))
    assert "journey.check_in_duress" in actions


def test_covert_sos_hidden_and_loud_sos_shown(client, user, make_user, clock, db) -> None:
    other = make_user("other@college.edu")
    quiet, loud = start(client, user), start(client, other)
    assert act(client, user, quiet["id"], "sos", {"covert": True}).json()["state"] == "active"
    assert act(client, other, loud["id"], "sos", {}).json()["state"] == "full_escalation"
    assert db_journey(db, quiet["id"]).state == "full_escalation"


def test_covert_journey_can_appear_to_end_and_a_new_one_can_start(client, user, clock, db) -> None:
    journey = start(client, user)
    act(client, user, journey["id"], "check-in", {"result": "duress"})
    resp = act(client, user, journey["id"], "arrive")
    assert resp.status_code == 200
    assert resp.json()["state"] == "resolved" and resp.json()["outcome"] == "arrived"
    assert current(client, user).status_code == 404
    again = act(client, user, journey["id"], "check-in", {"result": "ok"})
    assert again.status_code == 409 and again.json()["detail"] == "journey_over"

    assert db_journey(db, journey["id"]).state == "full_escalation"  # alarm still running
    start(client, user)


def test_covert_journey_not_advanced_or_cancelled_by_watchdog(client, user, clock, db) -> None:
    journey = start(client, user)
    act(client, user, journey["id"], "sos", {"covert": True})
    clock.advance(500)
    assert current(client, user).json()["state"] == "active"
    assert db_journey(db, journey["id"]).state == "full_escalation"


# --- ending --------------------------------------------------------------------------------


def test_arrive_then_nothing_else_works(client, user, clock) -> None:
    journey = start(client, user)
    resp = act(client, user, journey["id"], "arrive")
    assert resp.json()["state"] == "resolved" and resp.json()["outcome"] == "arrived"
    for action, body in [("check-in", {"result": "ok"}), ("heartbeat", None), ("sos", {})]:
        resp = act(client, user, journey["id"], action, body)
        assert resp.status_code == 409 and resp.json()["detail"] == "journey_over"
    assert current(client, user).status_code == 404


def test_cannot_end_during_contact_alert(client, user, clock) -> None:
    journey = start(client, user)
    clock.advance(12)  # phone silent past the 10-min heartbeat timeout
    resp = act(client, user, journey["id"], "end")
    assert resp.status_code == 409 and resp.json()["detail"] == "invalid_for_state"
    assert current(client, user).json()["state"] == "contact_alert"


def test_other_users_journey_is_not_found(client, user, make_user, clock) -> None:
    journey = start(client, user)
    stranger = make_user("stranger@college.edu")
    for action, body in [("check-in", {"result": "ok"}), ("heartbeat", None), ("end", None)]:
        assert act(client, stranger, journey["id"], action, body).status_code == 404


# --- watchdog job, retention, privacy ------------------------------------------------------


def test_run_watchdog_reports_newly_escalated(client, user, make_user, db, clock) -> None:
    other = make_user("other@college.edu")
    for person in (user, other):
        client.put(
            "/journeys/protocol", json={"heartbeat_timeout_min": 120}, headers=person["headers"]
        )
    quiet = start(client, user)
    other_journey = start(client, other, check_in_interval_min=240)
    mine = lambda result: [(e.journey_id, e.state) for e in result if e.journey_id in ids]  # noqa: E731
    ids = {quiet["id"], other_journey["id"]}  # the dev database may hold journeys from manual runs
    escalated = service.run_watchdog(db, T0 + timedelta(minutes=19))
    assert mine(escalated) == [(quiet["id"], "contact_alert")]
    assert mine(service.run_watchdog(db, T0 + timedelta(minutes=19))) == []  # nothing new


def test_purge_drops_journeys_ended_over_7_days_ago(client, user, db, clock) -> None:
    old = start(client, user)
    act(client, user, old["id"], "end")
    clock.advance(60)
    recent = start(client, user)
    act(client, user, recent["id"], "end")
    db.execute(
        update(Journey)
        .where(Journey.id == uuid.UUID(old["id"]))
        .values(ended_at=T0 - timedelta(days=8))
    )
    assert service.purge_expired(db, T0) == 1
    assert db_journey(db, old["id"]) is None
    assert db_journey(db, recent["id"]) is not None


def test_journeys_table_has_no_location_or_destination() -> None:
    columns = {c.key for c in inspect(Journey).columns}
    for banned in (
        "lat",
        "lng",
        "lon",
        "latitude",
        "longitude",
        "location",
        "destination",
        "route",
    ):
        assert not any(banned in column for column in columns)
