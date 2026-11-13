# ruff: noqa: F811
"""Audio clips through the relay (SOS recording, Audio Escort) and escort sessions."""

import uuid
from datetime import UTC, datetime, timedelta

from app.escort.models import AudioEscort, EscortRequest
from app.journey.models import Journey
from tests.test_relay import (  # noqa: F401  (fixtures)
    envelope,
    nothing_pending,
    open_socket,
    setup,
    test_sessions,
)


def clip(setup, recipient: str = "asha", size: int = 18_000) -> dict:
    return envelope(setup, recipient, ciphertext="A" * size)


def close(*sockets) -> None:
    for socket in sockets:
        socket.__exit__(None, None, None)


def sos(client, setup) -> None:
    resp = client.post(
        f"/journeys/{setup['journey']}/sos", json={}, headers=setup["owner"]["headers"]
    )
    assert resp.status_code == 200


def start_escort(client, setup, minutes: int = 30, **extra):
    return client.post(
        "/escorts",
        json={
            "journey_id": setup["journey"],
            "minutes": minutes,
            "contact_link_ids": [setup["link"]],
            **extra,
        },
        headers=setup["owner"]["headers"],
    )


# --- audio during an alert -------------------------------------------------------------------


def test_nobody_hears_anything_outside_an_alert_or_escort(client, setup) -> None:
    owner_socket, owner = open_socket(client, setup["owner"])
    owner.send_json({"type": "audio", "envelopes": [clip(setup)]})
    assert owner.receive_json() == {"type": "error", "detail": "not_listening"}
    close(owner_socket)


def test_contacts_hear_the_traveller_after_sos(client, setup) -> None:
    sos(client, setup)
    contact_socket, contact = open_socket(client, setup["asha"])
    stranger_socket, stranger = open_socket(client, setup["stranger"])
    owner_socket, owner = open_socket(client, setup["owner"])
    sent = clip(setup)
    owner.send_json({"type": "audio", "envelopes": [sent, clip(setup, "stranger")]})
    assert owner.receive_json() == {"type": "sent", "delivered": 1, "offline": 0, "not_allowed": 1}
    frame = contact.receive_json()
    assert frame["type"] == "audio" and frame["envelope"] == sent
    assert frame["sender"]["key_id"] == setup["keys"]["owner"]["key_id"]
    assert nothing_pending(stranger)
    close(owner_socket, stranger_socket, contact_socket)


def test_audio_clip_size_is_limited(client, setup) -> None:
    sos(client, setup)
    owner_socket, owner = open_socket(client, setup["owner"])
    owner.send_json({"type": "audio", "envelopes": [clip(setup, size=70_000)]})
    assert owner.receive_json() == {"type": "error", "detail": "bad_envelope"}
    # Location keeps its small limit.
    owner.send_json({"type": "location", "envelopes": [clip(setup, size=3_000)]})
    assert owner.receive_json() == {"type": "error", "detail": "bad_envelope"}
    close(owner_socket)


def test_helpers_cannot_send_audio_on_someone_elses_journey(client, setup) -> None:
    sos(client, setup)
    contact_socket, contact = open_socket(client, setup["asha"])
    contact.send_json({"type": "audio", "envelopes": [clip(setup, "owner")]})
    assert contact.receive_json() == {"type": "error", "detail": "no_open_journey"}
    close(contact_socket)


def test_offline_contact_gets_missed_clips_when_they_reconnect(client, setup) -> None:
    sos(client, setup)
    owner_socket, owner = open_socket(client, setup["owner"])
    first, second = clip(setup, size=100), clip(setup, size=200)
    for sent in (first, second):
        owner.send_json({"type": "audio", "envelopes": [sent]})
        assert owner.receive_json() == {
            "type": "sent",
            "delivered": 0,
            "offline": 1,
            "not_allowed": 0,
        }
    contact_socket, contact = open_socket(client, setup["asha"])
    assert contact.receive_json()["envelope"] == first
    assert contact.receive_json()["envelope"] == second
    assert nothing_pending(contact)
    close(contact_socket)
    # Handed over once, then gone from the server.
    contact_socket, contact = open_socket(client, setup["asha"])
    assert nothing_pending(contact)
    close(contact_socket, owner_socket)


def test_missed_clips_are_dropped_once_the_alert_is_over(client, setup, db, redis) -> None:
    sos(client, setup)
    owner_socket, owner = open_socket(client, setup["owner"])
    owner.send_json({"type": "audio", "envelopes": [clip(setup)]})
    assert owner.receive_json()["offline"] == 1
    db.get(Journey, uuid.UUID(setup["journey"])).state = "resolved"
    db.flush()
    contact_socket, contact = open_socket(client, setup["asha"])
    assert nothing_pending(contact)
    assert redis.keys("relay:pending:*") == []
    close(contact_socket, owner_socket)


def test_queued_clips_expire_and_are_capped(client, setup, redis) -> None:
    sos(client, setup)
    owner_socket, owner = open_socket(client, setup["owner"])
    owner.send_json({"type": "audio", "envelopes": [clip(setup, size=50)]})
    owner.receive_json()
    key = f"relay:pending:{setup['asha']['device_id']}"
    assert 0 < redis.ttl(key) <= 24 * 3600
    close(owner_socket)


def test_location_is_still_never_queued(client, setup, redis) -> None:
    sos(client, setup)
    owner_socket, owner = open_socket(client, setup["owner"])
    owner.send_json({"type": "location", "envelopes": [envelope(setup, "asha")]})
    assert owner.receive_json()["offline"] == 1
    assert redis.keys("relay:pending:*") == []
    close(owner_socket)


# --- audio escort ----------------------------------------------------------------------------


def test_escort_listeners_hear_the_owner_without_an_alert(client, setup) -> None:
    started = start_escort(client, setup, minutes=60)
    assert started.status_code == 201
    body = started.json()
    assert body["listener_link_ids"] == [setup["link"]]

    listening = client.get("/escorts/listening", headers=setup["asha"]["headers"]).json()
    assert [e["journey_id"] for e in listening["escorts"]] == [setup["journey"]]
    assert listening["escorts"][0]["owner_label"] == "Priya"
    assert client.get("/escorts/listening", headers=setup["stranger"]["headers"]).json() == {
        "escorts": []
    }

    contact_socket, contact = open_socket(client, setup["asha"])
    owner_socket, owner = open_socket(client, setup["owner"])
    owner.send_json({"type": "audio", "envelopes": [clip(setup), clip(setup, "stranger")]})
    assert owner.receive_json() == {"type": "sent", "delivered": 1, "offline": 0, "not_allowed": 1}
    assert contact.receive_json()["type"] == "audio"
    close(owner_socket, contact_socket)


def test_escort_rules(client, setup, make_user) -> None:
    assert start_escort(client, setup, minutes=181).status_code == 422
    assert start_escort(client, setup, minutes=4).status_code == 422
    resp = client.post(
        "/escorts",
        json={
            "journey_id": setup["journey"],
            "minutes": 30,
            "contact_link_ids": [str(uuid.uuid4())],
        },
        headers=setup["owner"]["headers"],
    )
    assert resp.status_code == 422 and resp.json()["detail"] == "unknown_contact"
    # Only the owner can start one on their journey.
    resp = client.post(
        "/escorts",
        json={"journey_id": setup["journey"], "minutes": 30, "contact_link_ids": [setup["link"]]},
        headers=setup["asha"]["headers"],
    )
    assert resp.status_code == 404
    assert start_escort(client, setup).status_code == 201
    assert start_escort(client, setup).json()["detail"] == "escort_already_on"
    assert client.get("/escorts/current", headers=setup["owner"]["headers"]).status_code == 200


def test_escort_ends_by_itself(client, setup, db) -> None:
    escort_id = start_escort(client, setup).json()["id"]
    db.get(AudioEscort, uuid.UUID(escort_id)).ends_at = datetime.now(UTC) - timedelta(seconds=1)
    db.flush()
    assert client.get("/escorts/listening", headers=setup["asha"]["headers"]).json() == {
        "escorts": []
    }
    owner_socket, owner = open_socket(client, setup["owner"])
    owner.send_json({"type": "audio", "envelopes": [clip(setup)]})
    assert owner.receive_json() == {"type": "error", "detail": "not_listening"}
    close(owner_socket)
    assert client.get("/escorts/current", headers=setup["owner"]["headers"]).status_code == 404
    assert db.get(AudioEscort, uuid.UUID(escort_id)).end_reason == "expired"


def test_stop_with_real_pin_ends_listening(client, setup) -> None:
    escort_id = start_escort(client, setup).json()["id"]
    resp = client.post(
        f"/escorts/{escort_id}/stop", json={"result": "ok"}, headers=setup["owner"]["headers"]
    )
    assert resp.json() == {"stopped": True}
    owner_socket, owner = open_socket(client, setup["owner"])
    owner.send_json({"type": "audio", "envelopes": [clip(setup)]})
    assert owner.receive_json() == {"type": "error", "detail": "not_listening"}
    close(owner_socket)
    journey = client.get("/journeys/current", headers=setup["owner"]["headers"]).json()
    assert journey["state"] == "active"


def test_stop_with_duress_pin_looks_the_same_but_raises_a_silent_alarm(client, setup, db) -> None:
    escort_id = start_escort(client, setup).json()["id"]
    resp = client.post(
        f"/escorts/{escort_id}/stop", json={"result": "duress"}, headers=setup["owner"]["headers"]
    )
    assert resp.json() == {"stopped": True}
    assert client.get("/escorts/current", headers=setup["owner"]["headers"]).status_code == 404
    # The phone still sees a normal journey...
    journey = client.get("/journeys/current", headers=setup["owner"]["headers"]).json()
    assert journey["state"] == "active"
    # ...while contacts are alerted and keep hearing the owner.
    assert db.get(Journey, uuid.UUID(setup["journey"])).state == "full_escalation"
    contact_socket, contact = open_socket(client, setup["asha"])
    owner_socket, owner = open_socket(client, setup["owner"])
    owner.send_json({"type": "audio", "envelopes": [clip(setup)]})
    assert owner.receive_json()["delivered"] == 1
    assert contact.receive_json()["type"] == "audio"
    close(owner_socket, contact_socket)


def test_others_cannot_stop_my_escort(client, setup) -> None:
    escort_id = start_escort(client, setup).json()["id"]
    resp = client.post(
        f"/escorts/{escort_id}/stop", json={"result": "ok"}, headers=setup["asha"]["headers"]
    )
    assert resp.status_code == 404


# --- requests --------------------------------------------------------------------------------


def test_contact_can_ask_and_only_the_owner_decides(client, setup, db) -> None:
    asked = client.post(
        "/escorts/requests",
        json={"contact_link_id": setup["link"]},
        headers=setup["asha"]["headers"],
    )
    assert asked.status_code == 201
    again = client.post(
        "/escorts/requests",
        json={"contact_link_id": setup["link"]},
        headers=setup["asha"]["headers"],
    )
    assert again.json()["id"] == asked.json()["id"]  # one pending request, not a flood
    stranger = client.post(
        "/escorts/requests",
        json={"contact_link_id": setup["link"]},
        headers=setup["stranger"]["headers"],
    )
    assert stranger.status_code == 404

    pending = client.get("/escorts/requests", headers=setup["owner"]["headers"]).json()
    assert [r["contact_link_id"] for r in pending["requests"]] == [setup["link"]]
    assert client.get("/escorts/requests", headers=setup["asha"]["headers"]).json() == {
        "requests": []
    }

    started = start_escort(client, setup, request_id=asked.json()["id"])
    assert started.status_code == 201
    assert db.get(EscortRequest, uuid.UUID(asked.json()["id"])).status == "accepted"
    assert client.get("/escorts/requests", headers=setup["owner"]["headers"]).json() == {
        "requests": []
    }


def test_owner_can_say_no(client, setup) -> None:
    asked = client.post(
        "/escorts/requests",
        json={"contact_link_id": setup["link"]},
        headers=setup["asha"]["headers"],
    ).json()
    resp = client.post(
        f"/escorts/requests/{asked['id']}/decline", headers=setup["owner"]["headers"]
    )
    assert resp.json() == {"stopped": True}
    assert client.get("/escorts/requests", headers=setup["owner"]["headers"]).json() == {
        "requests": []
    }


def test_escort_ends_with_the_journey(client, setup) -> None:
    start_escort(client, setup)
    client.post(f"/journeys/{setup['journey']}/end", headers=setup["owner"]["headers"])
    assert client.get("/escorts/listening", headers=setup["asha"]["headers"]).json() == {
        "escorts": []
    }
    assert client.get("/escorts/current", headers=setup["owner"]["headers"]).status_code == 404


def test_contact_sees_who_they_support(client, setup) -> None:
    people = client.get("/escorts/supporting", headers=setup["asha"]["headers"]).json()
    assert people == {"people": [{"contact_link_id": setup["link"], "owner_label": "Priya"}]}
    assert client.get("/escorts/supporting", headers=setup["stranger"]["headers"]).json() == {
        "people": []
    }
