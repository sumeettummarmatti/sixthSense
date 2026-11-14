# ruff: noqa: F811  (pytest fixtures imported from other test modules)
"""Rate helpers, suspend on 1 star, ban and restore (P2-W4-helper-ban)."""

import uuid
from datetime import UTC, datetime

import pytest
from fastapi import HTTPException
from sqlalchemy import select
from test_alerts import Clock, FakeSender, people, senders  # noqa: F401  (fixtures)
from test_relay import raw_key, test_sessions  # noqa: F401
from test_responders import (
    NEAR_300M,
    clock,  # noqa: F401
    going,
    offers,
    responder,
    sos_with_area,
    tick,
)
from test_walks import accepted_walk, companion, profile

from app.core.audit import AuditEvent
from app.identity.models import Account, Device
from app.matching.models import ResponderProfile
from app.moderation import service as moderation
from app.moderation.models import BannedIdentity, ModerationCase
from app.verification.models import FaceTemplate, IdentityRecord
from app.walks.models import CompanionProfile

NOW = datetime(2026, 11, 15, 12, 0, tzinfo=UTC)


def _ended_walk(client, db, make_user, owner):
    profile(client, owner, "Priya")
    owner["journey"] = client.post("/journeys", json={}, headers=owner["headers"]).json()["id"]
    riya = companion(client, db, make_user, "Riya", NEAR_300M)
    walk = accepted_walk(client, owner, riya)
    client.post(f"/walks/{walk['id']}/end", headers=riya["headers"])
    return walk, riya


def _rate_walk(client, owner, walk, stars):
    return client.post(
        "/feedback",
        json={
            "journey_id": owner["journey"],
            "walk_id": walk["id"],
            "route_stars": 3,
            "companion_stars": stars,
        },
        headers=owner["headers"],
    )


def _responder_who_came(client, db, redis, senders, clock, make_user, people):
    riya = responder(client, db, make_user, "Riya", NEAR_300M)
    journey = sos_with_area(client, people["owner"])
    tick(db, redis, senders, clock)
    [offer] = offers(client, riya)
    assert going(client, riya, offer["id"]).status_code == 200
    return riya, journey, offer


def test_one_star_companion_is_suspended(client, db, make_user, people, clock) -> None:
    owner = people["owner"]
    walk, riya = _ended_walk(client, db, make_user, owner)
    assert _rate_walk(client, owner, walk, 1).status_code == 201
    case = db.scalars(select(ModerationCase)).one()
    assert (case.role, case.status, case.stars) == ("companion", "suspended", 1)
    assert db.get(CompanionProfile, uuid.UUID(riya["account_id"])).status == "revoked"
    actions = set(db.scalars(select(AuditEvent.action)))
    assert "moderation.suspended.companion" in actions


def test_three_stars_suspends_nobody(client, db, make_user, people, clock) -> None:
    owner = people["owner"]
    walk, riya = _ended_walk(client, db, make_user, owner)
    assert _rate_walk(client, owner, walk, 3).status_code == 201
    assert db.scalars(select(ModerationCase)).first() is None
    assert db.get(CompanionProfile, uuid.UUID(riya["account_id"])).status == "approved"


def test_traveller_rates_each_responder_who_came(
    client, db, redis, senders, clock, make_user, people
) -> None:
    owner = people["owner"]
    riya, journey, offer = _responder_who_came(client, db, redis, senders, clock, make_user, people)
    listed = client.get(f"/feedback/responders/{journey}", headers=owner["headers"]).json()
    assert listed == {"responders": [{"offer_id": offer["id"], "name": "Riya"}]}
    # Only the traveller can rate, and only once.
    stranger = client.post(
        "/feedback/responder", json={"offer_id": offer["id"], "stars": 1}, headers=riya["headers"]
    )
    assert stranger.status_code == 404
    rated = client.post(
        "/feedback/responder",
        json={"offer_id": offer["id"], "stars": 1, "note": "Never showed up"},
        headers=owner["headers"],
    )
    assert rated.status_code == 201, rated.text
    again = client.post(
        "/feedback/responder", json={"offer_id": offer["id"], "stars": 5}, headers=owner["headers"]
    )
    assert again.status_code == 409
    after = client.get(f"/feedback/responders/{journey}", headers=owner["headers"]).json()
    assert after == {"responders": []}
    # 1 star: suspended from responding at once.
    profile_row = db.get(ResponderProfile, (uuid.UUID(riya["account_id"]), "responder"))
    assert profile_row.status == "revoked"
    case = db.scalars(select(ModerationCase)).one()
    assert (case.role, case.status) == ("responder", "suspended")


def test_ban_blocks_the_account_and_keeps_face_and_id(
    client, db, redis, make_user, people, clock
) -> None:
    owner = people["owner"]
    walk, riya = _ended_walk(client, db, make_user, owner)
    riya_id = uuid.UUID(riya["account_id"])
    db.add(
        FaceTemplate(
            account_id=riya_id,
            embedding_enc=b"encrypted-embedding",
            calculator_version="facenet.Calculator",
            consent_version="walk-face-template-v1",
            consent_at=NOW,
        )
    )
    db.flush()
    _rate_walk(client, owner, walk, 1)
    case = db.scalars(select(ModerationCase)).one()
    identity = db.get(IdentityRecord, riya_id)
    assert client.get("/verification/me", headers=riya["headers"]).status_code == 200

    moderation.ban(db, redis, case, NOW)
    db.commit()

    assert case.status == "banned" and db.get(Account, riya_id).status == "suspended"
    assert identity.revoked_reason == "banned"
    assert all(d.revoked_at for d in db.scalars(select(Device).where(Device.account_id == riya_id)))
    banned = db.scalars(select(BannedIdentity)).one()
    assert banned.id_hmac == identity.id_hmac and banned.embedding_enc == b"encrypted-embedding"
    # The live token stops working at once, and signing in again is refused.
    assert client.get("/verification/me", headers=riya["headers"]).status_code == 401
    assert moderation.banned_hashes(db, identity.id_hmac, b"other")


def test_restore_lets_them_help_again(client, db, make_user, people, clock) -> None:
    owner = people["owner"]
    walk, riya = _ended_walk(client, db, make_user, owner)
    _rate_walk(client, owner, walk, 1)
    case = db.scalars(select(ModerationCase)).one()
    moderation.restore(db, case, NOW)
    db.commit()
    assert case.status == "restored"
    assert db.get(CompanionProfile, uuid.UUID(riya["account_id"])).status == "approved"


def test_banned_selfie_is_refused_at_verification(db, monkeypatch) -> None:
    from app.core.config import Settings
    from app.verification import service as verification
    from app.verification.face_match import FaceComparison

    settings = Settings(compreface_api_key="k", face_matcher="compreface")
    comparison = FaceComparison(0.95, [0.1] * 4, "facenet.Calculator", [0.2] * 4)
    monkeypatch.setattr(verification, "decrypt_embedding", lambda s, enc: [0.3] * 4)
    monkeypatch.setattr(verification, "best_embedding_match", lambda s, e, t: 0.97)
    banned = [(b"enc", "facenet.Calculator")]
    assert verification._banned_face(settings, comparison, banned) is True
    monkeypatch.setattr(verification, "best_embedding_match", lambda s, e, t: 0.2)
    assert verification._banned_face(settings, comparison, banned) is False
    # No selfie embedding while a ban list exists: fail closed.
    with pytest.raises(HTTPException) as exc:
        verification._banned_face(settings, FaceComparison(0.95), banned)
    assert exc.value.status_code == 503


ADMIN = ("admin", "a-long-test-admin-password")


@pytest.fixture
def admin(client):
    from app.core.config import Settings, get_settings
    from app.main import app

    app.dependency_overrides[get_settings] = lambda: Settings(
        admin_username=ADMIN[0], admin_password=ADMIN[1]
    )
    from app.feedback.admin import _csrf

    return _csrf(Settings(admin_password=ADMIN[1]))


def test_admin_sees_the_queue_and_bans_from_it(client, db, make_user, people, clock, admin):
    owner = people["owner"]
    walk, riya = _ended_walk(client, db, make_user, owner)
    _rate_walk(client, owner, walk, 1)
    case = db.scalars(select(ModerationCase)).one()
    page = client.get("/admin/feedback", auth=ADMIN).text
    assert "Waiting for a decision" in page and str(case.id)[:8] in page
    assert "Riya" not in page and riya["account_id"] not in page  # never who (rule 4)
    # Without the CSRF token nothing happens.
    refused = client.post(f"/admin/feedback/cases/{case.id}/ban", data={"csrf": "x"}, auth=ADMIN)
    assert refused.status_code == 403 and case.status == "suspended"
    done = client.post(
        f"/admin/feedback/cases/{case.id}/ban",
        data={"csrf": admin},
        auth=ADMIN,
        follow_redirects=False,
    )
    assert done.status_code == 303
    db.refresh(case)
    assert case.status == "banned"


def test_admin_can_ban_from_any_rating(client, db, make_user, people, clock, admin):
    owner = people["owner"]
    walk, riya = _ended_walk(client, db, make_user, owner)
    feedback = _rate_walk(client, owner, walk, 4).json()["id"]
    assert db.scalars(select(ModerationCase)).first() is None
    resp = client.post(
        "/admin/feedback/ban",
        data={"csrf": admin, "source": f"feedback:{feedback}"},
        auth=ADMIN,
        follow_redirects=False,
    )
    assert resp.status_code == 303
    case = db.scalars(select(ModerationCase)).one()
    assert (case.status, case.role) == ("banned", "companion")
    assert db.get(Account, uuid.UUID(riya["account_id"])).status == "suspended"


def test_admin_restore(client, db, make_user, people, clock, admin):
    owner = people["owner"]
    walk, riya = _ended_walk(client, db, make_user, owner)
    _rate_walk(client, owner, walk, 1)
    case = db.scalars(select(ModerationCase)).one()
    client.post(f"/admin/feedback/cases/{case.id}/restore", data={"csrf": admin}, auth=ADMIN)
    db.refresh(case)
    assert case.status == "restored"
    assert db.get(CompanionProfile, uuid.UUID(riya["account_id"])).status == "approved"
