# ruff: noqa: F811  (pytest fixtures imported from other test modules)
"""Walk With Me (P3-W3): joining as a companion after identity verification (no approval step),
availability, matching, the face scan on accept, handshake, two-way E2E location, ending,
revocation, and SOS during a walk."""

import subprocess
import sys
import uuid
from pathlib import Path

import pytest
from sqlalchemy import select
from test_alerts import Clock, FakeSender, people, senders  # noqa: F401  (fixtures)
from test_relay import open_socket, raw_key, test_sessions  # noqa: F401
from test_responders import (
    FAR_3KM,
    HOME,
    NEAR_300M,
    NEAR_800M,
    SCAN,
    keys_for,
    tick,
    verified_identity,
)

from app.core.audit import AuditEvent
from app.core.config import Settings, get_settings
from app.escalation.models import EscalationRecipient
from app.escalation.router import _now as escalation_now
from app.journey.router import _now as journey_now
from app.main import app
from app.matching.router import _now as responders_now
from app.walks import service
from app.walks.models import Walk
from app.walks.router import _now as walks_now

PROFILE = {"bio": "", "strengths": [], "languages": [], "gender": None}


@pytest.fixture
def clock(client) -> Clock:
    clock = Clock()
    for dep in (journey_now, escalation_now, responders_now, walks_now):
        app.dependency_overrides[dep] = lambda: clock.now
    return clock


def profile(client, user, name: str, gender=None, willing=False, **extra) -> None:
    body = {**PROFILE, "first_name": name, "gender": gender, "willing_companion": willing, **extra}
    assert client.put("/profile", json=body, headers=user["headers"]).status_code == 200


def companion(
    client, db, make_user, name: str, at, gender="woman", verified=True, available=True
) -> dict:
    """Joins as a companion. A verified identity is all it takes: there is no approval."""
    user = make_user(f"{name.lower()}@college.edu")
    user["keys"] = keys_for(client, user)
    client.put(
        "/notifications/push-token", json={"fcm_token": f"{name}-fcm"}, headers=user["headers"]
    )
    profile(
        client,
        user,
        name,
        gender=gender,
        willing=True,
        bio=f"{name} walks this way daily",
        strengths=["first_aid_trained"],
    )
    if not verified:
        return user
    verified_identity(db, user["account_id"])
    joined = client.post("/walks/companion/join", headers=user["headers"]).json()
    assert joined["status"] == "approved" and joined["identity_verified"] is True
    if available:
        resp = client.put(
            "/walks/companion/presence",
            json={"latitude": at[0], "longitude": at[1]},
            headers=user["headers"],
        )
        assert resp.status_code == 200, resp.text
    return user


def accept(client, walk_id: str, user, scan=True):
    return client.post(
        f"/walks/{walk_id}/accept", headers=user["headers"], files=SCAN if scan else None
    )


@pytest.fixture
def traveller(client, people) -> dict:  # noqa: F811
    owner = people["owner"]
    profile(client, owner, "Priya", gender="woman")
    owner["keys"] = keys_for(client, owner)
    owner["journey"] = client.post("/journeys", json={}, headers=owner["headers"]).json()["id"]
    return owner


def search(client, traveller, women_only=False, at=HOME) -> list[dict]:
    resp = client.post(
        "/walks/search",
        json={
            "journey_id": traveller["journey"],
            "latitude": at[0],
            "longitude": at[1],
            "women_only": women_only,
        },
        headers=traveller["headers"],
    )
    assert resp.status_code == 200, resp.text
    return resp.json()["companions"]


def ask(client, traveller, who, at=HOME):
    return client.post(
        "/walks",
        json={
            "journey_id": traveller["journey"],
            "companion_id": who["account_id"],
            "latitude": at[0],
            "longitude": at[1],
        },
        headers=traveller["headers"],
    )


def accepted_walk(client, traveller, riya) -> dict:
    walk = ask(client, traveller, riya).json()
    resp = accept(client, walk["id"], riya)
    assert resp.status_code == 200, resp.text
    return resp.json()


# --- joining as a companion ---------------------------------------------------------------------


def test_join_needs_willing_profile_and_verified_identity(client, db, make_user, clock) -> None:
    user = make_user("x@college.edu")
    assert client.post("/walks/companion/join", headers=user["headers"]).status_code == 409
    profile(client, user, "Xen", willing=True)
    resp = client.post("/walks/companion/join", headers=user["headers"])
    assert resp.status_code == 409 and resp.json()["detail"] == "identity_not_verified"
    me = client.get("/walks/companion/me", headers=user["headers"]).json()
    assert me["status"] == "none" and me["identity_verified"] is False

    verified_identity(db, user["account_id"])
    me = client.post("/walks/companion/join", headers=user["headers"]).json()
    assert me == {
        "status": "approved",
        "identity_verified": True,
        "verified_method": "identity",
        "verified_at": clock.now.isoformat().replace("+00:00", "Z"),
        "available": False,
    }
    # No approval step: they can go available straight away.
    resp = client.put(
        "/walks/companion/presence",
        json={"latitude": HOME[0], "longitude": HOME[1]},
        headers=user["headers"],
    )
    assert resp.status_code == 200


def test_mock_verify_endpoint_is_gone(client, make_user) -> None:
    user = make_user("old@college.edu")
    assert client.post("/walks/companion/verify", headers=user["headers"]).status_code in (
        404,
        405,
    )


def test_revoked_companion_cannot_rejoin_or_go_available(
    client, db, redis, make_user, clock
) -> None:
    riya = companion(client, db, make_user, "Riya", NEAR_300M)
    service.revoke_companion(db, redis, uuid.UUID(riya["account_id"]), clock.now)
    assert client.post("/walks/companion/join", headers=riya["headers"]).status_code == 403
    resp = client.put(
        "/walks/companion/presence",
        json={"latitude": HOME[0], "longitude": HOME[1]},
        headers=riya["headers"],
    )
    assert resp.status_code == 403 and resp.json()["detail"] == "not_eligible"


# --- matching ---------------------------------------------------------------------------------


def test_search_lists_available_verified_companions_nearest_first(
    client, db, make_user, traveller, clock
) -> None:
    companion(client, db, make_user, "Riya", NEAR_800M)
    companion(client, db, make_user, "Meera", NEAR_300M)
    companion(client, db, make_user, "Far", FAR_3KM)
    companion(client, db, make_user, "Unverified", NEAR_300M, verified=False)
    companion(client, db, make_user, "Away", NEAR_300M, available=False)
    cards = search(client, traveller)
    assert [c["profile"]["first_name"] for c in cards] == ["Meera", "Riya"]
    assert cards[0]["distance_m"] % 100 == 0 and cards[0]["walk_minutes"] >= 1
    assert cards[0]["profile"]["strengths"] == ["first_aid_trained"]
    assert "gender" not in cards[0]["profile"]
    assert cards[0]["rating"] is None and cards[0]["rating_count"] == 0


def test_women_only_filter(client, db, make_user, traveller, clock) -> None:
    companion(client, db, make_user, "Riya", NEAR_300M, gender="woman")
    companion(client, db, make_user, "Arun", NEAR_300M, gender="man")
    companion(client, db, make_user, "Sam", NEAR_300M, gender=None)
    assert len(search(client, traveller)) == 3
    assert [c["profile"]["first_name"] for c in search(client, traveller, women_only=True)] == [
        "Riya"
    ]


def test_search_needs_my_open_journey(client, db, make_user, traveller, people) -> None:  # noqa: F811
    asha = people["asha"]
    resp = client.post(
        "/walks/search",
        json={"journey_id": traveller["journey"], "latitude": HOME[0], "longitude": HOME[1]},
        headers=asha["headers"],
    )
    assert resp.status_code == 404  # not her journey: nobody browses companions casually


def test_stale_presence_drops_out(client, db, make_user, traveller, clock) -> None:
    companion(client, db, make_user, "Riya", NEAR_300M)
    clock.advance(get_settings().companion_presence_ttl_seconds + 1)
    assert search(client, traveller) == []


def test_companion_sees_first_name_and_rough_area_then_accepts(
    client,
    db,
    make_user,
    traveller,
    senders,
    clock,  # noqa: F811
) -> None:
    riya = companion(client, db, make_user, "Riya", NEAR_300M)
    asked = ask(client, traveller, riya)
    assert asked.status_code == 201, asked.text
    walk = asked.json()
    assert walk["status"] == "requested" and walk["role"] == "traveller"
    assert walk["partner"]["first_name"] == "Riya" and walk["handshake_code"] is None
    pushed = senders.push.sent[-1][1]
    assert "Priya" in pushed.body and "walk" in pushed.title.lower()

    [request] = client.get("/walks/requests", headers=riya["headers"]).json()["requests"]
    assert request["traveller_first_name"] == "Priya"
    assert request["rough_area"] == {"latitude": round(HOME[0], 3), "longitude": round(HOME[1], 3)}
    assert request["distance_m"] % 100 == 0
    # Before accepting, the companion sees no profile and no handshake.
    assert client.get("/walks/current", headers=riya["headers"]).status_code == 404

    accepted = accept(client, walk["id"], riya).json()
    mine = client.get("/walks/current", headers=traveller["headers"]).json()
    assert accepted["status"] == mine["status"] == "accepted"
    assert accepted["handshake_code"] == mine["handshake_code"]
    assert len(mine["handshake_code"]) == 4 and mine["handshake_code"].isdigit()
    assert accepted["partner"]["first_name"] == "Priya" and accepted["journey_id"] is None
    assert accepted["meet_near"] == request["rough_area"]
    assert mine["partner_keys"][0]["key_id"] == riya["keys"]["key_id"]
    assert accepted["partner_keys"][0]["key_id"] == traveller["keys"]["key_id"]
    # Busy companions are not offered to anyone else.
    assert search(client, traveller) == []


def test_decline_and_expiry(client, db, make_user, traveller, clock) -> None:
    riya = companion(client, db, make_user, "Riya", NEAR_300M)
    walk = ask(client, traveller, riya).json()
    client.post(f"/walks/{walk['id']}/decline", headers=riya["headers"])
    assert (
        client.get(f"/walks/{walk['id']}", headers=traveller["headers"]).json()["status"]
        == "declined"
    )

    walk = ask(client, traveller, riya).json()
    clock.advance(get_settings().walk_request_ttl_seconds + 1)
    client.put(
        "/walks/companion/presence",
        json={"latitude": NEAR_300M[0], "longitude": NEAR_300M[1]},
        headers=riya["headers"],
    )
    assert client.get("/walks/requests", headers=riya["headers"]).json()["requests"] == []
    resp = accept(client, walk["id"], riya)
    assert resp.status_code == 409 and resp.json()["detail"] == "walk_expired"


def test_one_open_request_per_traveller_and_cancel(client, db, make_user, traveller, clock) -> None:
    riya = companion(client, db, make_user, "Riya", NEAR_300M)
    meera = companion(client, db, make_user, "Meera", NEAR_800M)
    walk = ask(client, traveller, riya).json()
    resp = ask(client, traveller, meera)
    assert resp.status_code == 409 and resp.json()["detail"] == "walk_already_open"
    client.post(f"/walks/{walk['id']}/cancel", headers=traveller["headers"])
    assert ask(client, traveller, meera).status_code == 201


def test_cannot_ask_unavailable_or_self(client, db, make_user, traveller, clock) -> None:
    away = companion(client, db, make_user, "Away", NEAR_300M, available=False)
    assert ask(client, traveller, away).json()["detail"] == "companion_unavailable"
    assert ask(client, traveller, traveller).status_code == 422


def test_strangers_cannot_touch_a_walk(client, db, make_user, traveller, people, clock) -> None:  # noqa: F811
    riya = companion(client, db, make_user, "Riya", NEAR_300M)
    walk = ask(client, traveller, riya).json()
    stranger = people["asha"]
    for path in ("accept", "decline", "end", "cancel"):
        assert (
            client.post(f"/walks/{walk['id']}/{path}", headers=stranger["headers"]).status_code
            == 404
        )
    assert client.get(f"/walks/{walk['id']}", headers=stranger["headers"]).status_code == 404
    # The traveller cannot accept their own request.
    assert (
        client.post(f"/walks/{walk['id']}/accept", headers=traveller["headers"]).status_code == 404
    )


# --- face scan on accept ---------------------------------------------------------------------


def test_accept_needs_a_fresh_face_scan(client, db, make_user, traveller, clock) -> None:
    riya = companion(client, db, make_user, "Riya", NEAR_300M)
    walk = ask(client, traveller, riya).json()
    missing = accept(client, walk["id"], riya, scan=False)
    assert missing.status_code == 428 and missing.json()["detail"] == "face_scan_required"
    wrong_type = client.post(
        f"/walks/{walk['id']}/accept",
        headers=riya["headers"],
        files={"selfie_image": ("scan.gif", b"GIF89a", "image/gif")},
    )
    assert wrong_type.status_code == 415
    mine = client.get("/walks/current", headers=traveller["headers"]).json()
    assert mine["status"] == "requested" and mine["partner_keys"] == []

    accepted = accept(client, walk["id"], riya)
    assert accepted.status_code == 200 and accepted.json()["status"] == "accepted"
    actions = [a for (a,) in db.execute(select(AuditEvent.action))]
    assert "walk.face_scan.passed.mock" in actions


def test_face_mismatch_leaves_the_walk_unaccepted(
    client, db, make_user, traveller, clock, monkeypatch
) -> None:
    from app.face_scan import service as face_scan

    app.dependency_overrides[get_settings] = lambda: Settings(face_check_provider="compreface")
    monkeypatch.setattr(face_scan, "check_walk_selfie", lambda *args, **kwargs: False)
    try:
        riya = companion(client, db, make_user, "Riya", NEAR_300M)
        walk = ask(client, traveller, riya).json()
        resp = accept(client, walk["id"], riya)
        assert resp.status_code == 403 and resp.json()["detail"] == "face_mismatch"
    finally:
        app.dependency_overrides.pop(get_settings, None)
    mine = client.get("/walks/current", headers=traveller["headers"]).json()
    assert mine["status"] == "requested" and mine["handshake_code"] is None
    actions = [a for (a,) in db.execute(select(AuditEvent.action))]
    assert "walk.face_scan.failed.compreface" in actions


def test_unverified_or_revoked_companions_are_not_found_or_asked(
    client, db, redis, make_user, traveller, clock
) -> None:
    from app.verification.models import IdentityRecord

    riya = companion(client, db, make_user, "Riya", NEAR_300M)
    meera = companion(client, db, make_user, "Meera", NEAR_300M)
    db.get(IdentityRecord, uuid.UUID(riya["account_id"])).revoked_at = clock.now
    service.revoke_companion(db, redis, uuid.UUID(meera["account_id"]), clock.now)
    db.flush()
    assert search(client, traveller) == []
    assert ask(client, traveller, riya).json()["detail"] == "companion_unavailable"


def test_revoking_a_companion_ends_their_walk(
    client, db, redis, make_user, traveller, clock
) -> None:
    riya = companion(client, db, make_user, "Riya", NEAR_300M)
    walk = accepted_walk(client, traveller, riya)
    service.revoke_companion(db, redis, uuid.UUID(riya["account_id"]), clock.now)
    db.flush()
    ended = client.get(f"/walks/{walk['id']}", headers=traveller["headers"]).json()
    assert ended["status"] == "ended" and ended["end_reason"] == "companion_revoked"


# --- ending -----------------------------------------------------------------------------------


def test_either_side_ends_and_journey_keeps_running(
    client, db, redis, make_user, traveller, clock
) -> None:
    riya = companion(client, db, make_user, "Riya", NEAR_300M)
    walk = accepted_walk(client, traveller, riya)
    ended = client.post(f"/walks/{walk['id']}/end", headers=riya["headers"]).json()
    assert ended["status"] == "ended" and ended["end_reason"] == "companion"
    assert ended["handshake_code"] is None and ended["partner_keys"] == []
    assert service.area_of(redis, uuid.UUID(walk["id"])) is None  # rough area forgotten
    journey = client.get("/journeys/current", headers=traveller["headers"]).json()
    assert journey["id"] == traveller["journey"] and journey["state"] == "active"
    assert client.post(f"/walks/{walk['id']}/end", headers=traveller["headers"]).status_code == 409


def test_walk_ends_with_the_journey(client, db, make_user, traveller, clock) -> None:
    riya = companion(client, db, make_user, "Riya", NEAR_300M)
    walk = accepted_walk(client, traveller, riya)
    client.post(f"/journeys/{traveller['journey']}/end", headers=traveller["headers"])
    view = client.get(f"/walks/{walk['id']}", headers=riya["headers"]).json()
    assert view["status"] == "ended" and view["end_reason"] == "journey_over"


# --- live location between the two walkers ---------------------------------------------------


def _env(session: str, sender_key: str, recipient_key: str) -> dict:
    return {
        "v": 1,
        "session_id": session,
        "sender_key_id": sender_key,
        "recipient_key_id": recipient_key,
        "ephemeral_public_key": raw_key(),
        "nonce": "bm9uY2U=",
        "ciphertext": "c2VjcmV0",
        "mac": "bWFj",
        "signature": "c2ln",
    }


def test_relay_between_walkers_only(
    client,
    db,
    make_user,
    traveller,
    people,
    clock,  # noqa: F811
) -> None:
    riya = companion(client, db, make_user, "Riya", NEAR_300M)
    walk = ask(client, traveller, riya).json()
    t_key, r_key = traveller["keys"]["key_id"], riya["keys"]["key_id"]
    t_socket, t_ws = open_socket(client, traveller)
    r_socket, r_ws = open_socket(client, riya)
    try:
        # Not accepted yet: nothing flows.
        t_ws.send_json({"type": "location", "envelopes": [_env(walk["id"], t_key, r_key)]})
        assert t_ws.receive_json() == {"type": "error", "detail": "no_open_journey"}

        # Accepting without a face scan is refused, so still nothing flows.
        assert accept(client, walk["id"], riya, scan=False).status_code == 428
        t_ws.send_json({"type": "location", "envelopes": [_env(walk["id"], t_key, r_key)]})
        assert t_ws.receive_json() == {"type": "error", "detail": "no_open_journey"}

        assert accept(client, walk["id"], riya).status_code == 200
        t_ws.send_json({"type": "location", "envelopes": [_env(walk["id"], t_key, r_key)]})
        assert t_ws.receive_json()["delivered"] == 1
        assert r_ws.receive_json()["type"] == "location"
        r_ws.send_json({"type": "location", "envelopes": [_env(walk["id"], r_key, t_key)]})
        assert r_ws.receive_json()["delivered"] == 1
        assert t_ws.receive_json()["type"] == "location"

        # The walk session reaches nobody else (not even the traveller's contacts).
        asha_key = keys_for(client, people["asha"])["key_id"]
        t_ws.send_json({"type": "location", "envelopes": [_env(walk["id"], t_key, asha_key)]})
        assert t_ws.receive_json()["not_allowed"] == 1

        client.post(f"/walks/{walk['id']}/end", headers=traveller["headers"])
        r_ws.send_json({"type": "location", "envelopes": [_env(walk["id"], r_key, t_key)]})
        assert r_ws.receive_json() == {"type": "error", "detail": "no_open_journey"}
    finally:
        t_socket.__exit__(None, None, None)
        r_socket.__exit__(None, None, None)


# --- SOS during a walk -----------------------------------------------------------------------


def test_sos_during_walk_alerts_companion_who_cannot_close_it(
    client,
    db,
    redis,
    make_user,
    traveller,
    senders,
    clock,  # noqa: F811
) -> None:
    riya = companion(client, db, make_user, "Riya", NEAR_300M)
    accepted_walk(client, traveller, riya)
    client.post(f"/journeys/{traveller['journey']}/sos", json={}, headers=traveller["headers"])
    tick(db, redis, senders, clock)

    recipients = db.scalars(select(EscalationRecipient)).all()
    kinds = {str(r.contact_account_id): r.kind for r in recipients}
    assert kinds[riya["account_id"]] == "companion"
    assert sum(1 for kind in kinds.values() if kind == "contact") == 2  # Asha and Ben too
    assert any("Riya-fcm" == target for target, _ in senders.push.sent)

    [alert] = client.get("/escalations/active", headers=riya["headers"]).json()["escalations"]
    assert alert["owner_label"] == "Priya" and alert["level"] == "full_escalation"
    # "I'm on it" shows her as coming but keeps alerting the trusted contacts.
    assert (
        client.post(f"/escalations/{alert['id']}/ack", headers=riya["headers"]).status_code == 200
    )
    assert (
        client.get("/escalations/active", headers=riya["headers"]).json()["escalations"][0][
            "acknowledged"
        ]
        is False
    )
    helpers = client.get(
        f"/escalations/help/{traveller['journey']}", headers=traveller["headers"]
    ).json()["helpers"]
    assert [h["label"] for h in helpers] == ["Riya"]
    # A companion can never close or change the alarm.
    for path in ("resolve", "raise"):
        resp = client.post(f"/escalations/{alert['id']}/{path}", headers=riya["headers"])
        assert resp.status_code == 403 and resp.json()["detail"] == "contacts_only"


def test_sos_without_walk_does_not_alert_companions(
    client,
    db,
    redis,
    make_user,
    traveller,
    senders,
    clock,  # noqa: F811
) -> None:
    riya = companion(client, db, make_user, "Riya", NEAR_300M)
    client.post(f"/journeys/{traveller['journey']}/sos", json={}, headers=traveller["headers"])
    tick(db, redis, senders, clock)
    assert client.get("/escalations/active", headers=riya["headers"]).json()["escalations"] == []


# --- rating and the admin script -------------------------------------------------------------


def test_rating_comes_from_walk_feedback(client, db, make_user, traveller, clock) -> None:
    riya = companion(client, db, make_user, "Riya", NEAR_300M)
    walk = accepted_walk(client, traveller, riya)
    client.post(f"/walks/{walk['id']}/end", headers=traveller["headers"])
    resp = client.post(
        "/feedback",
        json={
            "journey_id": traveller["journey"],
            "walk_id": walk["id"],
            "route_stars": 4,
            "companion_stars": 5,
        },
        headers=traveller["headers"],
    )
    assert resp.status_code == 201, resp.text
    client.put(
        "/walks/companion/presence",
        json={"latitude": NEAR_300M[0], "longitude": NEAR_300M[1]},
        headers=riya["headers"],
    )
    [card] = search(client, traveller)
    assert card["rating"] == 5.0 and card["rating_count"] == 1


def test_handshake_code_is_stable_and_four_digits() -> None:
    settings = Settings()
    walk_id = uuid.uuid4()
    code = service.handshake_code(settings, walk_id)
    assert code == service.handshake_code(settings, walk_id) and len(code) == 4


def test_companions_script_parses() -> None:
    script = Path(__file__).resolve().parent.parent / "scripts" / "companions.py"
    out = subprocess.run(  # noqa: S603  (our own script, fixed arguments)
        [sys.executable, str(script), "--help"], capture_output=True, text=True, check=True
    )
    assert "approve" not in out.stdout.split("revoke")[0].split("usage")[1]
    assert "list" in out.stdout and "revoke" in out.stdout


def test_walk_rows_hold_no_location(db) -> None:
    columns = {c.name for c in Walk.__table__.columns}
    assert not any(word in name for name in columns for word in ("lat", "lng", "lon", "area"))
