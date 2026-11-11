import base64
import logging
import os
from contextlib import nullcontext

import pytest
from starlette.websockets import WebSocketDisconnect

from app.core.db import get_session_factory
from app.main import app


@pytest.fixture(autouse=True)
def test_sessions(client, db):
    """The relay opens a session per message; point it at the test transaction."""
    app.dependency_overrides[get_session_factory] = lambda: lambda: nullcontext(db)


def raw_key() -> str:
    return base64.b64encode(os.urandom(32)).decode()


def upload_keys(client, user) -> dict:
    resp = client.put(
        "/auth/device/e2e-keys",
        json={"x25519_public_key": raw_key(), "ed25519_public_key": raw_key()},
        headers=user["headers"],
    )
    return resp.json()


def connect_contact(client, owner, contact) -> str:
    invite = client.post(
        "/contacts/invites", json={"owner_label": "Priya"}, headers=owner["headers"]
    ).json()
    client.post(
        "/contacts/invites/accept",
        json={"invite_token": invite["invite_token"]},
        headers=contact["headers"],
    )
    return invite["contact_link_id"]


@pytest.fixture
def setup(client, make_user):
    owner, asha, stranger = (make_user(f"{n}@college.edu") for n in ("owner", "asha", "stranger"))
    link = connect_contact(client, owner, asha)
    keys = {"owner": upload_keys(client, owner), "asha": upload_keys(client, asha)}
    keys["stranger"] = upload_keys(client, stranger)
    journey = client.post("/journeys", json={}, headers=owner["headers"]).json()
    return {
        "owner": owner,
        "asha": asha,
        "stranger": stranger,
        "keys": keys,
        "journey": journey["id"],
        "link": link,
    }


def envelope(setup, recipient: str, **override) -> dict:
    body = {
        "v": 1,
        "session_id": setup["journey"],
        "sender_key_id": setup["keys"]["owner"]["key_id"],
        "recipient_key_id": setup["keys"][recipient]["key_id"],
        "ephemeral_public_key": raw_key(),
        "nonce": "bm9uY2U=",
        "ciphertext": "c2VjcmV0LWNvb3Jkcw==",
        "mac": "bWFj",
        "signature": "c2ln",
    }
    return {**body, **override}


def token(user) -> str:
    return user["headers"]["Authorization"].removeprefix("Bearer ")


def open_socket(client, user):
    socket = client.websocket_connect("/relay/ws")
    ws = socket.__enter__()
    ws.send_json({"type": "auth", "access_token": token(user)})
    assert ws.receive_json() == {"type": "ready"}
    return socket, ws


def nothing_pending(ws) -> bool:
    """A ping answered by the very next frame proves nothing else was queued before it."""
    ws.send_json({"type": "ping"})
    return ws.receive_json() == {"type": "pong"}


# --- auth ----------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "first", [{"type": "ping"}, {"type": "auth", "access_token": "nope"}, {"type": "auth"}]
)
def test_must_authenticate_first(client, first) -> None:
    with client.websocket_connect("/relay/ws") as ws:
        ws.send_json(first)
        with pytest.raises(WebSocketDisconnect) as exc:
            ws.receive_json()
        assert exc.value.code == 4401


def test_expired_token_closes_the_socket(client, setup, redis) -> None:
    socket, ws = open_socket(client, setup["asha"])
    for key in redis.keys("at:*"):
        redis.delete(key)
    ws.send_json({"type": "ping"})
    assert ws.receive_json() == {"type": "error", "detail": "token_expired"}
    with pytest.raises(WebSocketDisconnect) as exc:
        ws.receive_json()
    assert exc.value.code == 4401
    socket.__exit__(None, None, None)


# --- relaying ------------------------------------------------------------------------------


def test_contact_receives_envelope_unchanged_with_sender_key(client, setup) -> None:
    contact_socket, contact = open_socket(client, setup["asha"])
    owner_socket, owner = open_socket(client, setup["owner"])
    sent = envelope(setup, "asha")
    owner.send_json({"type": "location", "envelopes": [sent]})
    assert owner.receive_json() == {"type": "sent", "delivered": 1, "offline": 0, "not_allowed": 0}
    frame = contact.receive_json()
    assert frame == {
        "type": "location",
        "envelope": sent,
        "sender": {
            "key_id": setup["keys"]["owner"]["key_id"],
            "ed25519_public_key": setup["keys"]["owner"]["ed25519_public_key"],
        },
    }
    owner_socket.__exit__(None, None, None)
    contact_socket.__exit__(None, None, None)


def test_offline_contact_gets_nothing_later(client, setup) -> None:
    owner_socket, owner = open_socket(client, setup["owner"])
    owner.send_json({"type": "location", "envelopes": [envelope(setup, "asha")]})
    assert owner.receive_json() == {"type": "sent", "delivered": 0, "offline": 1, "not_allowed": 0}
    contact_socket, contact = open_socket(client, setup["asha"])
    assert nothing_pending(contact)  # dropped, never queued or stored
    owner_socket.__exit__(None, None, None)
    contact_socket.__exit__(None, None, None)


def test_strangers_and_removed_contacts_get_nothing(client, setup) -> None:
    stranger_socket, stranger = open_socket(client, setup["stranger"])
    owner_socket, owner = open_socket(client, setup["owner"])
    owner.send_json({"type": "location", "envelopes": [envelope(setup, "stranger")]})
    assert owner.receive_json()["not_allowed"] == 1
    assert nothing_pending(stranger)

    client.delete(f"/contacts/{setup['link']}", headers=setup["owner"]["headers"])
    owner.send_json({"type": "location", "envelopes": [envelope(setup, "asha")]})
    assert owner.receive_json() == {"type": "sent", "delivered": 0, "offline": 0, "not_allowed": 1}
    owner_socket.__exit__(None, None, None)
    stranger_socket.__exit__(None, None, None)


def test_protocol_alert_list_limits_who_receives(client, setup, make_user) -> None:
    other = make_user("other@college.edu")
    other_link = connect_contact(client, setup["owner"], other)
    client.post(f"/journeys/{setup['journey']}/end", headers=setup["owner"]["headers"])
    client.put(
        "/journeys/protocol",
        json={"alert_contact_ids": [other_link]},
        headers=setup["owner"]["headers"],
    )
    setup["journey"] = client.post("/journeys", json={}, headers=setup["owner"]["headers"]).json()[
        "id"
    ]
    owner_socket, owner = open_socket(client, setup["owner"])
    owner.send_json({"type": "location", "envelopes": [envelope(setup, "asha")]})
    assert owner.receive_json()["not_allowed"] == 1
    owner_socket.__exit__(None, None, None)


def test_location_keeps_flowing_during_a_silent_alarm(client, setup) -> None:
    client.post(
        f"/journeys/{setup['journey']}/check-in",
        json={"result": "duress"},
        headers=setup["owner"]["headers"],
    )
    client.post(f"/journeys/{setup['journey']}/end", headers=setup["owner"]["headers"])
    contact_socket, contact = open_socket(client, setup["asha"])
    owner_socket, owner = open_socket(client, setup["owner"])
    owner.send_json({"type": "location", "envelopes": [envelope(setup, "asha")]})
    assert owner.receive_json()["delivered"] == 1
    assert contact.receive_json()["type"] == "location"
    owner_socket.__exit__(None, None, None)
    contact_socket.__exit__(None, None, None)


# --- rejections ----------------------------------------------------------------------------


def test_nothing_relayed_after_the_journey_ends(client, setup) -> None:
    client.post(f"/journeys/{setup['journey']}/arrive", headers=setup["owner"]["headers"])
    owner_socket, owner = open_socket(client, setup["owner"])
    owner.send_json({"type": "location", "envelopes": [envelope(setup, "asha")]})
    assert owner.receive_json() == {"type": "error", "detail": "no_open_journey"}
    owner_socket.__exit__(None, None, None)


def test_cannot_send_for_someone_elses_journey(client, setup) -> None:
    socket, ws = open_socket(client, setup["asha"])
    upload = setup["keys"]["asha"]["key_id"]
    ws.send_json(
        {"type": "location", "envelopes": [envelope(setup, "owner", sender_key_id=upload)]}
    )
    assert ws.receive_json() == {"type": "error", "detail": "no_open_journey"}
    socket.__exit__(None, None, None)


def test_stale_sender_key_rejected(client, setup) -> None:
    owner_socket, owner = open_socket(client, setup["owner"])
    upload_keys(client, setup["owner"])  # rotated: old key_id no longer valid
    owner.send_json({"type": "location", "envelopes": [envelope(setup, "asha")]})
    assert owner.receive_json() == {"type": "error", "detail": "stale_sender_key"}
    owner_socket.__exit__(None, None, None)


@pytest.mark.parametrize(
    ("make", "detail"),
    [
        (lambda s: [], "bad_envelopes"),
        (lambda s: "nope", "bad_envelopes"),
        (lambda s: [envelope(s, "asha")] * 11, "bad_envelopes"),
        (lambda s: [{**envelope(s, "asha"), "lat": 12.97}], "bad_envelope"),
        (lambda s: [{k: v for k, v in envelope(s, "asha").items() if k != "mac"}], "bad_envelope"),
        (lambda s: [envelope(s, "asha", ciphertext="")], "bad_envelope"),
        (lambda s: [envelope(s, "asha", v=2)], "unsupported_version"),
        (
            lambda s: [envelope(s, "asha"), envelope(s, "asha", session_id="other")],
            "mixed_sessions",
        ),
    ],
)
def test_malformed_messages_rejected(client, setup, make, detail) -> None:
    owner_socket, owner = open_socket(client, setup["owner"])
    owner.send_json({"type": "location", "envelopes": make(setup)})
    assert owner.receive_json() == {"type": "error", "detail": detail}
    owner_socket.__exit__(None, None, None)


def test_rate_limited(client, setup) -> None:
    owner_socket, owner = open_socket(client, setup["owner"])
    replies = []
    for _ in range(11):
        owner.send_json({"type": "location", "envelopes": [envelope(setup, "asha")]})
        replies.append(owner.receive_json())
    assert replies[-1] == {"type": "error", "detail": "rate_limited"}
    assert all(reply["type"] == "sent" for reply in replies[:10])
    owner_socket.__exit__(None, None, None)


def test_ping_and_unknown_messages(client, setup) -> None:
    socket, ws = open_socket(client, setup["asha"])
    assert nothing_pending(ws)
    ws.send_json({"type": "dance"})
    assert ws.receive_json() == {"type": "error", "detail": "unknown_type"}
    ws.send_text("not json")
    assert ws.receive_json() == {"type": "error", "detail": "bad_json"}
    socket.__exit__(None, None, None)


def test_nothing_sensitive_in_logs(client, setup, caplog) -> None:
    caplog.set_level(logging.DEBUG)
    contact_socket, contact = open_socket(client, setup["asha"])
    owner_socket, owner = open_socket(client, setup["owner"])
    sent = envelope(setup, "asha")
    owner.send_json({"type": "location", "envelopes": [sent]})
    owner.receive_json()
    contact.receive_json()
    for secret in (sent["ciphertext"], sent["ephemeral_public_key"], token(setup["owner"])):
        assert secret not in caplog.text
    owner_socket.__exit__(None, None, None)
    contact_socket.__exit__(None, None, None)
