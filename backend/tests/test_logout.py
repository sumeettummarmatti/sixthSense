"""Sign out from Profile (P1-W4-logout)."""

import uuid

from sqlalchemy import select

from app.core.audit import AuditEvent
from app.identity.models import Device


def test_logout_ends_the_token_and_retires_the_device(client, db, make_user) -> None:
    user = make_user("bye@college.edu")
    assert client.get("/verification/me", headers=user["headers"]).status_code == 200
    assert client.post("/auth/logout", headers=user["headers"]).status_code == 204
    assert client.get("/verification/me", headers=user["headers"]).status_code == 401
    assert db.get(Device, uuid.UUID(user["device_id"])).revoked_at is not None
    assert "auth.logout" in set(db.scalars(select(AuditEvent.action)))
    # The same email signs in again on a new device key.
    again = make_user("bye@college.edu")
    assert again["account_id"] == user["account_id"] and again["device_id"] != user["device_id"]


def test_logout_needs_a_session(client) -> None:
    assert client.post("/auth/logout").status_code == 401
