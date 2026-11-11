import base64
import logging
import os
import uuid

import pytest
from sqlalchemy import select, update

from app.contacts.models import TrustedContact
from app.core.audit import AuditEvent
from app.identity.models import Device

ZERO_KEY = base64.b64encode(bytes(32)).decode()


def raw_key() -> str:
    return base64.b64encode(os.urandom(32)).decode()


@pytest.fixture
def owner(make_user):
    return make_user("owner@college.edu")


@pytest.fixture
def friend(make_user):
    return make_user("friend@college.edu")


def invite(client, user, label: str = "Priya") -> dict:
    resp = client.post("/contacts/invites", json={"owner_label": label}, headers=user["headers"])
    assert resp.status_code == 201, resp.text
    return resp.json()


def accept(client, user, token: str):
    return client.post(
        "/contacts/invites/accept", json={"invite_token": token}, headers=user["headers"]
    )


def link(client, owner, friend) -> str:
    created = invite(client, owner)
    assert accept(client, friend, created["invite_token"]).status_code == 200
    return created["contact_link_id"]


# --- auth -----------------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("method", "path"),
    [
        ("post", "/contacts/invites"),
        ("post", "/contacts/invites/accept"),
        ("get", "/contacts"),
        ("delete", f"/contacts/{uuid.uuid4()}"),
        ("get", f"/contacts/{uuid.uuid4()}/keys"),
        ("put", "/auth/device/e2e-keys"),
    ],
)
def test_every_endpoint_requires_sign_in(client, method, path) -> None:
    assert getattr(client, method)(path).status_code == 401


# --- invite, accept, list -------------------------------------------------------------------


def test_invite_accept_and_list(client, owner, friend, db) -> None:
    created = invite(client, owner, "  Priya  ")
    # token sits after '#', so browsers never send it to a web server
    assert created["invite_url"].endswith(f"#{created['invite_token']}")
    listed = client.get("/contacts", headers=owner["headers"]).json()["contacts"]
    assert [(c["id"], c["status"]) for c in listed] == [(created["contact_link_id"], "pending")]

    resp = accept(client, friend, created["invite_token"])
    assert resp.status_code == 200
    assert resp.json() == {"owner_label": "Priya"}

    listed = client.get("/contacts", headers=owner["headers"]).json()["contacts"]
    assert listed[0]["status"] == "accepted"
    assert listed[0]["invite_expires_at"] is None
    assert set(listed[0]) == {"id", "status", "created_at", "accepted_at", "invite_expires_at"}

    row = db.get(TrustedContact, uuid.UUID(created["contact_link_id"]))
    assert str(row.contact_id) == friend["account_id"]
    actions = set(db.scalars(select(AuditEvent.action)))
    assert {"contact.invite_created", "contact.accepted"} <= actions


def test_accepting_twice_is_a_no_op(client, owner, friend) -> None:
    created = invite(client, owner)
    assert accept(client, friend, created["invite_token"]).status_code == 200
    assert accept(client, friend, created["invite_token"]).status_code == 200
    assert len(client.get("/contacts", headers=owner["headers"]).json()["contacts"]) == 1


def test_invite_is_single_use(client, owner, friend, make_user) -> None:
    created = invite(client, owner)
    accept(client, friend, created["invite_token"])
    stranger = make_user("stranger@college.edu")
    resp = accept(client, stranger, created["invite_token"])
    assert resp.status_code == 404
    assert resp.json()["detail"] == "invite_invalid"


def test_expired_invite_rejected_and_hidden(client, owner, friend, db) -> None:
    created = invite(client, owner)
    db.execute(
        update(TrustedContact)
        .where(TrustedContact.id == uuid.UUID(created["contact_link_id"]))
        .values(invite_expires_at=TrustedContact.created_at)
    )
    assert accept(client, friend, created["invite_token"]).status_code == 404
    assert client.get("/contacts", headers=owner["headers"]).json()["contacts"] == []


def test_unknown_invite_rejected(client, friend) -> None:
    assert accept(client, friend, "made-up-token").status_code == 404


def test_cannot_add_yourself(client, owner) -> None:
    created = invite(client, owner)
    resp = accept(client, owner, created["invite_token"])
    assert resp.status_code == 400
    assert resp.json()["detail"] == "cannot_add_self"


def test_second_invite_to_existing_contact_does_not_duplicate(client, owner, friend) -> None:
    link(client, owner, friend)
    second = invite(client, owner, "Priya again")
    resp = accept(client, friend, second["invite_token"])
    assert resp.status_code == 200
    assert resp.json() == {"owner_label": "Priya"}
    assert len(client.get("/contacts", headers=owner["headers"]).json()["contacts"]) == 1


def test_contact_limit_counts_pending_and_accepted(client, owner, friend) -> None:
    link(client, owner, friend)
    for _ in range(4):
        invite(client, owner)
    resp = client.post("/contacts/invites", json={"owner_label": "x"}, headers=owner["headers"])
    assert resp.status_code == 409
    assert resp.json()["detail"] == "contact_limit_reached"


def test_expired_invites_free_up_slots(client, owner, db) -> None:
    for _ in range(5):
        invite(client, owner)
    db.execute(update(TrustedContact).values(invite_expires_at=TrustedContact.created_at))
    invite(client, owner)


def test_invite_rate_limit(client, owner, redis) -> None:
    redis.set(f"rl:invite:{owner['account_id']}", 10, ex=3600)
    resp = client.post("/contacts/invites", json={"owner_label": "x"}, headers=owner["headers"])
    assert resp.status_code == 429


@pytest.mark.parametrize("label", ["", "   ", "x" * 41])
def test_owner_label_validated(client, owner, label) -> None:
    resp = client.post("/contacts/invites", json={"owner_label": label}, headers=owner["headers"])
    assert resp.status_code == 422


# --- silent removal and rule 4 -------------------------------------------------------------


def test_silent_removal(client, owner, friend, mailer, db) -> None:
    link_id = link(client, owner, friend)
    emails_before = len(mailer.sent)
    resp = client.delete(f"/contacts/{link_id}", headers=owner["headers"])
    assert resp.status_code == 204
    assert len(mailer.sent) == emails_before  # nothing sent to anyone
    assert db.get(TrustedContact, uuid.UUID(link_id)) is None
    assert client.get("/contacts", headers=owner["headers"]).json()["contacts"] == []
    assert "contact.removed" in set(db.scalars(select(AuditEvent.action)))


def test_only_owner_can_remove(client, owner, friend) -> None:
    link_id = link(client, owner, friend)
    assert client.delete(f"/contacts/{link_id}", headers=friend["headers"]).status_code == 404
    assert client.delete(f"/contacts/{uuid.uuid4()}", headers=owner["headers"]).status_code == 404


def test_contact_cannot_see_who_they_watch_over(client, owner, friend) -> None:
    link(client, owner, friend)
    assert client.get("/contacts", headers=friend["headers"]).json()["contacts"] == []


def test_pending_invite_can_be_cancelled(client, owner, friend) -> None:
    created = invite(client, owner)
    resp = client.delete(f"/contacts/{created['contact_link_id']}", headers=owner["headers"])
    assert resp.status_code == 204
    assert accept(client, friend, created["invite_token"]).status_code == 404


# --- E2E keys ------------------------------------------------------------------------------


def test_upload_and_look_up_contact_keys(client, owner, friend) -> None:
    link_id = link(client, owner, friend)
    x, ed = raw_key(), raw_key()
    uploaded = client.put(
        "/auth/device/e2e-keys",
        json={"x25519_public_key": x, "ed25519_public_key": ed},
        headers=friend["headers"],
    )
    assert uploaded.status_code == 200
    resp = client.get(f"/contacts/{link_id}/keys", headers=owner["headers"])
    assert resp.status_code == 200
    assert resp.json() == {
        "contact_link_id": link_id,
        "keys": [
            {"key_id": uploaded.json()["key_id"], "x25519_public_key": x, "ed25519_public_key": ed}
        ],
    }


def test_reuploading_keys_replaces_them_with_new_key_id(client, owner, friend) -> None:
    link_id = link(client, owner, friend)
    body = {"x25519_public_key": raw_key(), "ed25519_public_key": raw_key()}
    first = client.put("/auth/device/e2e-keys", json=body, headers=friend["headers"]).json()
    body = {"x25519_public_key": raw_key(), "ed25519_public_key": raw_key()}
    second = client.put("/auth/device/e2e-keys", json=body, headers=friend["headers"]).json()
    assert first["key_id"] != second["key_id"]
    keys = client.get(f"/contacts/{link_id}/keys", headers=owner["headers"]).json()["keys"]
    assert [k["key_id"] for k in keys] == [second["key_id"]]


def test_keys_only_for_owner_of_accepted_link(client, owner, friend, make_user) -> None:
    pending = invite(client, owner)
    path = f"/contacts/{pending['contact_link_id']}/keys"
    assert client.get(path, headers=owner["headers"]).status_code == 404  # not accepted yet
    link_id = link(client, owner, friend)
    stranger = make_user("stranger@college.edu")
    assert client.get(f"/contacts/{link_id}/keys", headers=stranger["headers"]).status_code == 404
    assert client.get(f"/contacts/{link_id}/keys", headers=friend["headers"]).status_code == 404


def test_removed_contact_keys_no_longer_available(client, owner, friend) -> None:
    link_id = link(client, owner, friend)
    client.delete(f"/contacts/{link_id}", headers=owner["headers"])
    assert client.get(f"/contacts/{link_id}/keys", headers=owner["headers"]).status_code == 404


def test_revoked_device_keys_hidden(client, owner, friend, db) -> None:
    link_id = link(client, owner, friend)
    body = {"x25519_public_key": raw_key(), "ed25519_public_key": raw_key()}
    client.put("/auth/device/e2e-keys", json=body, headers=friend["headers"])
    db.execute(
        update(Device)
        .where(Device.id == uuid.UUID(friend["device_id"]))
        .values(revoked_at=Device.created_at)
    )
    assert client.get(f"/contacts/{link_id}/keys", headers=owner["headers"]).json()["keys"] == []


@pytest.mark.parametrize(
    "body",
    [
        {"x25519_public_key": "not base64!", "ed25519_public_key": raw_key()},
        {"x25519_public_key": raw_key(), "ed25519_public_key": base64.b64encode(b"short").decode()},
        {"x25519_public_key": ZERO_KEY, "ed25519_public_key": raw_key()},
    ],
)
def test_bad_e2e_keys_rejected(client, owner, body) -> None:
    resp = client.put("/auth/device/e2e-keys", json=body, headers=owner["headers"])
    assert resp.status_code == 422


# --- privacy -------------------------------------------------------------------------------


def test_no_tokens_or_labels_in_logs(client, owner, friend, caplog) -> None:
    caplog.set_level(logging.DEBUG)
    created = invite(client, owner, "Priya Sharma")
    accept(client, friend, created["invite_token"])
    for secret in (created["invite_token"], "Priya Sharma"):
        assert secret not in caplog.text
