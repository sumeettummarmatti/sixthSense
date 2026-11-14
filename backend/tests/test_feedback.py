# ruff: noqa: F811  (pytest fixtures imported from other test modules)
"""How was it? (P1-W3-journey-feedback) and the raw store + admin export (P2-W3)."""

import csv
import importlib.util
import uuid
from contextlib import nullcontext
from pathlib import Path

import pytest
from sqlalchemy import select
from test_alerts import Clock, FakeSender, people, senders  # noqa: F401  (fixtures)
from test_relay import raw_key, test_sessions  # noqa: F401
from test_responders import NEAR_300M
from test_walks import accepted_walk, clock, companion, profile  # noqa: F401

from app.core.audit import AuditEvent
from app.feedback.models import Feedback


def _script():
    path = Path(__file__).resolve().parent.parent / "scripts" / "feedback.py"
    spec = importlib.util.spec_from_file_location("feedback_script", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def journey(client, make_user) -> dict:
    owner = make_user("fb@college.edu")
    owner["journey"] = client.post("/journeys", json={}, headers=owner["headers"]).json()["id"]
    client.post(f"/journeys/{owner['journey']}/end", headers=owner["headers"])
    return owner


def post(client, user, **body):
    return client.post("/feedback", json=body, headers=user["headers"])


def test_journey_feedback_is_stored_raw(client, db, journey) -> None:
    resp = post(
        client,
        journey,
        journey_id=journey["journey"],
        route_stars=4,
        chips=["well_lit", "would_walk_again", "well_lit"],
        note="  Quiet stretch near the park after 10 pm.  ",
    )
    assert resp.status_code == 201, resp.text
    row = db.get(Feedback, uuid.UUID(resp.json()["id"]))
    assert row.route_stars == 4 and row.companion_stars is None and row.walk_id is None
    assert row.chips == ["well_lit", "would_walk_again"]
    assert row.note == "Quiet stretch near the park after 10 pm."
    audit = db.scalars(select(AuditEvent).where(AuditEvent.action == "feedback.created")).one()
    assert audit.target == f"feedback:{row.id}"


def test_feedback_has_no_location_or_names() -> None:
    columns = {c.name for c in Feedback.__table__.columns}
    assert columns == {
        "id",
        "journey_id",
        "walk_id",
        "route_stars",
        "companion_stars",
        "chips",
        "note",
        "created_at",
    }


def test_owner_only_once_and_validated(client, journey, make_user) -> None:
    other = make_user("other@college.edu")
    assert post(client, other, journey_id=journey["journey"], route_stars=3).status_code == 404
    for bad in (
        {"route_stars": 0},
        {"route_stars": 6},
        {"route_stars": 3, "chips": ["loved_it"]},
        {"route_stars": 3, "note": "x" * 501},
        {"route_stars": 3, "companion_stars": 4},  # no walk, so no companion stars
    ):
        assert post(client, journey, journey_id=journey["journey"], **bad).status_code == 422
    assert post(client, journey, journey_id=journey["journey"], route_stars=3).status_code == 201
    again = post(client, journey, journey_id=journey["journey"], route_stars=5)
    assert again.status_code == 409 and again.json()["detail"] == "feedback_already_given"


def test_walk_feedback_needs_an_ended_walk_on_that_journey(
    client,
    db,
    make_user,
    people,
    clock,  # noqa: F811
) -> None:
    owner = people["owner"]
    profile(client, owner, "Priya")
    owner["journey"] = client.post("/journeys", json={}, headers=owner["headers"]).json()["id"]
    riya = companion(client, db, make_user, "Riya", NEAR_300M)
    walk = accepted_walk(client, owner, riya)
    body = {
        "journey_id": owner["journey"],
        "walk_id": walk["id"],
        "route_stars": 4,
        "companion_stars": 5,
        "chips": ["companion_was_late"],
    }
    assert post(client, owner, **body).status_code == 404  # still walking
    client.post(f"/walks/{walk['id']}/end", headers=riya["headers"])
    assert post(client, owner, **body).status_code == 201
    # The companion does not own the journey, so cannot leave the traveller's feedback.
    assert post(client, riya, **body).status_code == 404
    # Journey feedback and walk feedback are separate rows for the same journey.
    assert post(client, owner, journey_id=owner["journey"], route_stars=3).status_code == 201


def test_admin_export_csv_and_audit(client, db, journey, tmp_path, monkeypatch) -> None:
    post(client, journey, journey_id=journey["journey"], route_stars=2, chips=["felt_uneasy"])
    script = _script()
    monkeypatch.setattr(script, "SessionLocal", lambda: nullcontext(db))
    out = tmp_path / "feedback.csv"
    script.main(["export", str(out)])
    with out.open() as handle:
        [row] = list(csv.DictReader(handle))
    assert row["route_stars"] == "2" and row["chips"] == "felt_uneasy"
    assert row["journey_id"] == journey["journey"] and row["companion_stars"] == ""
    assert list(row) == list(script.COLUMNS)
    script.main(["list"])
    actions = set(db.scalars(select(AuditEvent.action)))
    assert {"feedback.admin_export", "feedback.admin_list"} <= actions
