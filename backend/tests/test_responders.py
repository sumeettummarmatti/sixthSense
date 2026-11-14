# ruff: noqa: F811  (pytest fixtures imported from other test modules)
"""Who is coming (helpers) and nearby responders (P3-W1)."""

import uuid
from datetime import timedelta

import pytest
from sqlalchemy import select, update
from test_alerts import Clock, FakeSender, people, senders  # noqa: F401  (fixtures)
from test_relay import open_socket, raw_key, test_sessions  # noqa: F401

from app.core.audit import AuditEvent
from app.core.config import get_settings
from app.escalation import ladder
from app.escalation.models import Escalation, EscalationHelper
from app.escalation.router import _now as escalation_now
from app.journey import service as journeys
from app.journey.models import Journey
from app.journey.router import _now as journey_now
from app.main import app
from app.matching import nearby
from app.matching.models import ResponderOffer, ResponderProfile
from app.matching.router import _now as responders_now
from app.relay.routing import _active_helpers, _traveller_recipients
from app.verification.models import IdentityRecord
from app.verification.revocation import revoke_responder

# Brigade Millennium (JP Nagar) and points around it.
HOME = (12.8905, 77.5826)
NEAR_300M = (12.8932, 77.5826)
NEAR_800M = (12.8977, 77.5826)
FAR_3KM = (12.9175, 77.5826)

# A fresh face scan sent with "I'm going" / accepting a walk (mock provider: any real image).
JPEG = bytes([0xFF, 0xD8, 0xFF, 0xE0]) + bytes(64)
SCAN = {"selfie_image": ("scan.jpg", JPEG, "image/jpeg")}


@pytest.fixture
def clock(client) -> Clock:
    clock = Clock()
    for dep in (journey_now, escalation_now, responders_now):
        app.dependency_overrides[dep] = lambda: clock.now
    return clock


def tick(db, redis, senders, clock, seconds: float = 0) -> int:  # noqa: F811
    now = clock.advance(seconds)
    journeys.run_watchdog(db, now)
    closed = ladder.sync(db, get_settings(), now)
    ladder.send_due(db, senders, get_settings(), now)
    ladder.send_all_clear(db, senders, closed)
    return nearby.dispatch(db, redis, senders, get_settings(), now)


def keys_for(client, user) -> dict:
    return client.put(
        "/auth/device/e2e-keys",
        json={"x25519_public_key": raw_key(), "ed25519_public_key": raw_key()},
        headers=user["headers"],
    ).json()


def verified_identity(db, account_id: str) -> None:
    account = uuid.UUID(account_id)
    now = Clock().now
    db.add(
        IdentityRecord(
            account_id=account,
            id_type="drivers_license",
            id_hmac=account.bytes + account.bytes,
            person_hmac=account.bytes + account.bytes,
            hmac_key_version=1,
            is_adult=True,
            verified_by="test_provider",
            verified_at=now,
            valid_until=now + timedelta(days=365),
        )
    )
    db.flush()


def responder(client, db, make_user, name: str, at: tuple[float, float], verified=True) -> dict:
    """Applies as a responder. A verified identity is all it takes: there is no approval."""
    user = make_user(f"{name.lower()}@college.edu")
    user["keys"] = keys_for(client, user)
    if verified:
        verified_identity(db, user["account_id"])
    client.put(
        "/notifications/push-token", json={"fcm_token": f"{name}-fcm"}, headers=user["headers"]
    )
    assert client.post(
        "/responders/apply", json={"display_name": name}, headers=user["headers"]
    ).json() == {"status": "approved", "display_name": name, "on_duty": False}
    if verified:
        resp = client.put(
            "/responders/presence",
            json={"latitude": at[0], "longitude": at[1]},
            headers=user["headers"],
        )
        assert resp.status_code == 200, resp.text
    return user


def going(client, user, offer_id: str, scan=True):
    return client.post(
        f"/responders/offers/{offer_id}/going",
        headers=user["headers"],
        files=SCAN if scan else None,
    )


def sos_with_area(client, owner, at=HOME) -> str:
    journey = client.post("/journeys", json={}, headers=owner["headers"]).json()["id"]
    assert (
        client.post(f"/journeys/{journey}/sos", json={}, headers=owner["headers"]).status_code
        == 200
    )
    resp = client.put(
        f"/escalations/area/{journey}",
        json={"latitude": at[0], "longitude": at[1]},
        headers=owner["headers"],
    )
    assert resp.status_code == 204, resp.text
    return journey


def offers(client, user) -> list[dict]:
    return client.get("/responders/offers", headers=user["headers"]).json()["offers"]


def help_view(client, owner, journey) -> dict:
    return client.get(f"/escalations/help/{journey}", headers=owner["headers"]).json()


# --- helpers: contacts -----------------------------------------------------------------------


def test_contact_on_it_shows_up_for_the_traveller(client, db, redis, senders, clock, people):  # noqa: F811
    owner, asha = people["owner"], people["asha"]
    keys_for(client, asha)
    journey = sos_with_area(client, owner)
    tick(db, redis, senders, clock)
    assert help_view(client, owner, journey)["helpers"] == []

    [alert] = client.get("/escalations/active", headers=asha["headers"]).json()["escalations"]
    assert alert["i_am_helping"] is False
    client.post(f"/escalations/{alert['id']}/ack", headers=asha["headers"])

    view = help_view(client, owner, journey)
    assert view["full_alert"] is True
    [helper] = view["helpers"]
    assert helper["kind"] == "contact"
    assert helper["contact_link_id"] == people["links"]["asha"]
    assert helper["status"] == "going" and len(helper["keys"]) == 1
    [alert] = client.get("/escalations/active", headers=asha["headers"]).json()["escalations"]
    assert alert["i_am_helping"] is True and alert["helpers_going"] == 1

    # A second contact can say they are going too.
    ben = people["ben"]
    [ben_alert] = client.get("/escalations/active", headers=ben["headers"]).json()["escalations"]
    client.post(f"/escalations/{ben_alert['id']}/ack", headers=ben["headers"])
    assert len(help_view(client, owner, journey)["helpers"]) == 2

    keys = client.get(f"/escalations/{alert['id']}/owner-keys", headers=asha["headers"])
    assert keys.status_code == 200 and keys.json()["journey_id"] == journey


def test_owner_keys_only_for_helpers(client, db, redis, senders, clock, people):  # noqa: F811
    sos_with_area(client, people["owner"])
    tick(db, redis, senders, clock)
    [alert] = client.get("/escalations/active", headers=people["asha"]["headers"]).json()[
        "escalations"
    ]
    resp = client.get(f"/escalations/{alert['id']}/owner-keys", headers=people["asha"]["headers"])
    assert resp.status_code == 404


def test_help_view_is_owner_only(client, db, redis, senders, clock, people):  # noqa: F811
    journey = sos_with_area(client, people["owner"])
    resp = client.get(f"/escalations/help/{journey}", headers=people["asha"]["headers"])
    assert resp.status_code == 404


def test_area_only_during_a_full_alert(client, people):  # noqa: F811
    owner = people["owner"]
    journey = client.post("/journeys", json={}, headers=owner["headers"]).json()["id"]
    resp = client.put(
        f"/escalations/area/{journey}",
        json={"latitude": HOME[0], "longitude": HOME[1]},
        headers=owner["headers"],
    )
    assert resp.status_code == 409


# --- responders ------------------------------------------------------------------------------


def test_verified_applicant_goes_on_duty_without_approval(client, db, make_user):
    user = responder(client, db, make_user, "Riya", NEAR_300M)
    me = client.get("/responders/me", headers=user["headers"]).json()
    assert me["status"] == "approved" and me["on_duty"] is True


def test_unverified_applicant_cannot_go_on_duty(client, db, make_user):
    user = responder(client, db, make_user, "Riya", NEAR_300M, verified=False)
    resp = client.put(
        "/responders/presence",
        json={"latitude": NEAR_300M[0], "longitude": NEAR_300M[1]},
        headers=user["headers"],
    )
    assert resp.status_code == 403 and resp.json()["detail"] == "not_eligible"


def test_going_needs_a_fresh_face_scan(client, db, redis, senders, clock, make_user, people):
    riya = responder(client, db, make_user, "Riya", NEAR_300M)
    journey = sos_with_area(client, people["owner"])
    tick(db, redis, senders, clock)
    [offer] = offers(client, riya)

    missing = going(client, riya, offer["id"], scan=False)
    assert missing.status_code == 428 and missing.json()["detail"] == "face_scan_required"
    not_an_image = client.post(
        f"/responders/offers/{offer['id']}/going",
        headers=riya["headers"],
        files={"selfie_image": ("scan.jpg", b"not an image", "image/jpeg")},
    )
    assert not_an_image.status_code == 422
    # Nothing was shared: still only offered, no helper, no keys.
    assert offers(client, riya)[0]["status"] == "offered"
    assert help_view(client, people["owner"], journey)["helpers"] == []

    assert going(client, riya, offer["id"]).status_code == 200
    # Asking again once going (app restart) returns the keys without a new scan.
    assert going(client, riya, offer["id"], scan=False).status_code == 200
    actions = [a for (a,) in db.execute(select(AuditEvent.action))]
    assert "responder.face_scan.passed.mock" in actions


def test_face_mismatch_blocks_going(
    client, db, redis, senders, clock, make_user, people, monkeypatch
):
    from app.core.config import Settings
    from app.face_scan import service as face_scan
    from app.identity.router import get_settings as identity_settings

    app.dependency_overrides[identity_settings] = lambda: Settings(face_check_provider="compreface")
    monkeypatch.setattr(face_scan, "check_walk_selfie", lambda *args, **kwargs: False)
    try:
        riya = responder(client, db, make_user, "Riya", NEAR_300M)
        journey = sos_with_area(client, people["owner"])
        tick(db, redis, senders, clock)
        [offer] = offers(client, riya)
        resp = going(client, riya, offer["id"])
        assert resp.status_code == 403 and resp.json()["detail"] == "face_mismatch"
        assert offers(client, riya)[0]["status"] == "offered"
        assert help_view(client, people["owner"], journey)["helpers"] == []
    finally:
        app.dependency_overrides.pop(identity_settings, None)


def test_unverified_responder_is_gated_from_presence_dispatch_offers_and_going(
    client, db, redis, senders, clock, make_user, people
):
    user = make_user("unverified-responder@college.edu")
    user["keys"] = keys_for(client, user)
    client.post("/responders/apply", json={"display_name": "Riya"}, headers=user["headers"])
    db.execute(
        update(ResponderProfile)
        .where(ResponderProfile.account_id == uuid.UUID(user["account_id"]))
        .values(status="approved")
    )
    assert db.get(IdentityRecord, uuid.UUID(user["account_id"])) is None

    presence = client.put(
        "/responders/presence",
        json={"latitude": NEAR_300M[0], "longitude": NEAR_300M[1]},
        headers=user["headers"],
    )
    assert presence.status_code == 403 and presence.json()["detail"] == "not_eligible"

    # Simulate stale/forged Redis presence: dispatch must still check eligibility itself.
    nearby.set_presence(
        redis,
        uuid.UUID(user["account_id"]),
        nearby.rough(*NEAR_300M),
        clock.now,
    )
    journey = sos_with_area(client, people["owner"])
    assert tick(db, redis, senders, clock) == 0
    assert offers(client, user) == []

    escalation = db.scalar(
        select(Escalation).where(
            Escalation.journey_id == uuid.UUID(journey), Escalation.closed_at.is_(None)
        )
    )
    db.add(
        ResponderOffer(
            escalation_id=escalation.id,
            responder_id=uuid.UUID(user["account_id"]),
            distance_m=300,
            offered_at=clock.now,
        )
    )
    db.flush()
    assert offers(client, user) == []
    going = client.post(
        "/responders/offers/"
        + str(
            db.scalar(
                select(ResponderOffer.id).where(
                    ResponderOffer.responder_id == uuid.UUID(user["account_id"])
                )
            )
        )
        + "/going",
        headers=user["headers"],
    )
    assert going.status_code == 403 and going.json()["detail"] == "not_eligible"


def test_unverified_responder_is_removed_from_relay_allowlists(
    client, db, redis, senders, clock, make_user, people
):
    user = make_user("relay-unverified@college.edu")
    client.post("/responders/apply", json={"display_name": "Riya"}, headers=user["headers"])
    db.execute(
        update(ResponderProfile)
        .where(ResponderProfile.account_id == uuid.UUID(user["account_id"]))
        .values(status="approved")
    )
    journey_id = sos_with_area(client, people["owner"])
    tick(db, redis, senders, clock)
    escalation = db.scalar(select(Escalation).where(Escalation.journey_id == uuid.UUID(journey_id)))
    db.add(
        EscalationHelper(
            escalation_id=escalation.id,
            account_id=uuid.UUID(user["account_id"]),
            kind="responder",
            accepted_at=clock.now,
        )
    )
    db.flush()

    journey = db.get(Journey, uuid.UUID(journey_id))
    assert uuid.UUID(user["account_id"]) not in _traveller_recipients(db, journey)
    assert uuid.UUID(user["account_id"]) not in _active_helpers(db, journey.id)


def test_only_nearby_responders_are_asked_then_radius_grows(
    client,
    db,
    redis,
    senders,
    clock,
    make_user,
    people,  # noqa: F811
):
    near = responder(client, db, make_user, "Riya", NEAR_300M)
    middle = responder(client, db, make_user, "Kiran", NEAR_800M)
    far = responder(client, db, make_user, "Dev", FAR_3KM)
    sos_with_area(client, people["owner"])

    owner = people["owner"]
    journey = client.get("/journeys/current", headers=owner["headers"]).json()["id"]
    assert help_view(client, owner, journey)["search"] is None  # opens on the next tick

    assert tick(db, redis, senders, clock) == 1
    assert help_view(client, owner, journey)["search"] == {
        "radius_m": 500,
        "on_duty_nearby": 1,
        "asked": 1,
        "going": 0,
    }
    [offer] = offers(client, near)
    assert offer["status"] == "offered" and offer["journey_id"] is None
    assert 250 <= offer["distance_m"] <= 350 and offer["walk_minutes"] in (4, 5)
    assert offers(client, middle) == [] and offers(client, far) == []
    asks = [m for _, m in senders.telegram.sent + senders.push.sent if "nearby" in m.title]
    assert asks and all("Priya" not in m.title + m.body for m in asks)  # never told who

    assert tick(db, redis, senders, clock, 65) == 1  # 1 km after a minute
    assert len(offers(client, middle)) == 1 and offers(client, far) == []
    assert tick(db, redis, senders, clock, 65) == 0  # 2 km: still nobody at 3 km
    assert offers(client, far) == []


def test_going_gives_owner_keys_and_shows_responder(
    client,
    db,
    redis,
    senders,
    clock,
    make_user,
    people,  # noqa: F811
):
    riya = responder(client, db, make_user, "Riya", NEAR_300M)
    journey = sos_with_area(client, people["owner"])
    tick(db, redis, senders, clock)
    [offer] = offers(client, riya)

    resp = going(client, riya, offer["id"])
    assert resp.status_code == 200 and resp.json()["journey_id"] == journey
    [offer] = offers(client, riya)
    assert offer["status"] == "going" and offer["journey_id"] == journey

    [helper] = help_view(client, people["owner"], journey)["helpers"]
    assert helper["kind"] == "responder" and helper["label"] == "Riya"
    assert helper["keys"][0]["key_id"] == riya["keys"]["key_id"]

    assert (
        client.post(
            f"/responders/offers/{offer['id']}/arrived", headers=riya["headers"]
        ).status_code
        == 204
    )
    [helper] = help_view(client, people["owner"], journey)["helpers"]
    assert helper["status"] == "arrived"


def test_only_two_get_precise_location(client, db, redis, senders, clock, make_user, people):  # noqa: F811
    team = [responder(client, db, make_user, n, NEAR_300M) for n in ("Riya", "Kiran", "Dev")]
    sos_with_area(client, people["owner"])
    tick(db, redis, senders, clock)
    results = [
        going(client, r, offers(client, r)[0]["id"]) for r in team
    ]
    assert [r.status_code for r in results] == [200, 200, 409]
    assert results[2].json()["detail"] == "enough_helpers"


def test_contacts_are_not_asked_again_as_responders(
    client,
    db,
    redis,
    senders,
    clock,
    make_user,
    people,  # noqa: F811
):
    asha = people["asha"]
    db.add(
        ResponderProfile(
            account_id=uuid.UUID(asha["account_id"]),
            role="responder",
            display_name="Asha",
            status="approved",
            applied_at=clock.now,
        )
    )
    verified_identity(db, asha["account_id"])
    db.flush()
    client.put(
        "/responders/presence",
        json={"latitude": NEAR_300M[0], "longitude": NEAR_300M[1]},
        headers=asha["headers"],
    )
    sos_with_area(client, people["owner"])
    tick(db, redis, senders, clock)
    assert offers(client, asha) == []


def test_missed_check_in_does_not_ask_responders(
    client,
    db,
    redis,
    senders,
    clock,
    make_user,
    people,  # noqa: F811
):
    riya = responder(client, db, make_user, "Riya", NEAR_300M)
    client.post("/journeys", json={}, headers=people["owner"]["headers"])
    tick(db, redis, senders, clock, 10 * 60)  # contact alert only
    assert offers(client, riya) == []


def test_off_duty_and_stale_presence_are_not_asked(
    client,
    db,
    redis,
    senders,
    clock,
    make_user,
    people,  # noqa: F811
):
    riya = responder(client, db, make_user, "Riya", NEAR_300M)
    client.delete("/responders/presence", headers=riya["headers"])
    sos_with_area(client, people["owner"])
    assert tick(db, redis, senders, clock) == 0


def test_closed_alert_hides_offers(client, db, redis, senders, clock, make_user, people):  # noqa: F811
    riya = responder(client, db, make_user, "Riya", NEAR_300M)
    sos_with_area(client, people["owner"])
    tick(db, redis, senders, clock)
    assert len(offers(client, riya)) == 1
    asha = people["asha"]
    [alert] = client.get("/escalations/active", headers=asha["headers"]).json()["escalations"]
    assert (
        client.post(f"/escalations/{alert['id']}/resolve", headers=asha["headers"]).status_code
        == 200
    )
    assert offers(client, riya) == []


# --- relay: who may send to whom -------------------------------------------------------------


def test_relay_between_traveller_and_helpers(client, db, redis, senders, clock, make_user, people):  # noqa: F811
    owner = people["owner"]
    owner_keys = keys_for(client, owner)
    riya = responder(client, db, make_user, "Riya", NEAR_300M)
    journey = sos_with_area(client, owner)
    tick(db, redis, senders, clock)
    offer = offers(client, riya)[0]

    def env(sender_key: str, recipient_key: str) -> dict:
        return {
            "v": 1,
            "session_id": journey,
            "sender_key_id": sender_key,
            "recipient_key_id": recipient_key,
            "ephemeral_public_key": raw_key(),
            "nonce": "bm9uY2U=",
            "ciphertext": "c2VjcmV0",
            "mac": "bWFj",
            "signature": "c2ln",
        }

    owner_socket, owner_ws = open_socket(client, owner)
    riya_socket, riya_ws = open_socket(client, riya)
    try:
        # Before "I'm going": Riya may neither receive nor send.
        owner_ws.send_json(
            {"type": "location", "envelopes": [env(owner_keys["key_id"], riya["keys"]["key_id"])]}
        )
        assert owner_ws.receive_json()["not_allowed"] == 1
        riya_ws.send_json(
            {"type": "location", "envelopes": [env(riya["keys"]["key_id"], owner_keys["key_id"])]}
        )
        assert riya_ws.receive_json() == {"type": "error", "detail": "no_open_journey"}

        resp = going(client, riya, offer["id"])
        assert resp.status_code == 200, resp.text

        owner_ws.send_json(
            {"type": "location", "envelopes": [env(owner_keys["key_id"], riya["keys"]["key_id"])]}
        )
        assert owner_ws.receive_json() == {
            "type": "sent",
            "delivered": 1,
            "offline": 0,
            "not_allowed": 0,
        }
        assert riya_ws.receive_json()["type"] == "location"

        riya_ws.send_json(
            {"type": "location", "envelopes": [env(riya["keys"]["key_id"], owner_keys["key_id"])]}
        )
        assert riya_ws.receive_json() == {
            "type": "sent",
            "delivered": 1,
            "offline": 0,
            "not_allowed": 0,
        }
        assert owner_ws.receive_json()["type"] == "location"

        # A helper can only send to the traveller, never to other contacts.
        asha_keys = keys_for(client, people["asha"])
        riya_ws.send_json(
            {"type": "location", "envelopes": [env(riya["keys"]["key_id"], asha_keys["key_id"])]}
        )
        assert riya_ws.receive_json()["not_allowed"] == 1

        account_id = uuid.UUID(riya["account_id"])
        assert revoke_responder(db, redis, account_id, clock.now, "safety_concern")
        db.commit()
        assert redis.hget("responders:presence", str(account_id)) is None
        assert offers(client, riya) == []
        assert help_view(client, owner, journey)["helpers"] == []

        # Revocation takes effect on the next relay frame, even on an open socket.
        owner_ws.send_json(
            {"type": "location", "envelopes": [env(owner_keys["key_id"], riya["keys"]["key_id"])]}
        )
        assert owner_ws.receive_json() == {
            "type": "sent",
            "delivered": 0,
            "offline": 0,
            "not_allowed": 1,
        }
        riya_ws.send_json(
            {"type": "location", "envelopes": [env(riya["keys"]["key_id"], owner_keys["key_id"])]}
        )
        assert riya_ws.receive_json() == {"type": "error", "detail": "no_open_journey"}
    finally:
        owner_socket.__exit__(None, None, None)
        riya_socket.__exit__(None, None, None)
