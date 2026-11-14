"""Verification core: ordinary safety access stays available without ID verification."""

import uuid
from datetime import UTC, datetime, timedelta

from test_alerts import clock, people, senders, start_journey, tick  # noqa: F401

from app.matching.models import ResponderProfile
from app.verification.eligibility import eligible
from app.verification.models import IdentityRecord, VerificationSession
from app.verification.providers import MockProvider


def test_mock_verification_api_keeps_only_hmac_outcomes(
    client, db, make_user, monkeypatch
) -> None:
    import app.verification.service as verification_service

    monkeypatch.setattr(verification_service, "compare_faces", lambda *args, **kwargs: 0.91)
    user = make_user("verify-me@college.edu")
    session = client.post(
        "/verification/sessions",
        json={"purpose": "responder", "consent": True},
        headers=user["headers"],
    )
    assert session.status_code == 201
    assert session.json()["status"] == "not_submitted"
    verification_id = session.json()["id"]
    assert client.get("/verification/me", headers=user["headers"]).json()["status"] == (
        "not_submitted"
    )
    assert (
        client.get(
            f"/verification/sessions/{verification_id}", headers=user["headers"]
        ).json()["status"]
        == "not_submitted"
    )
    result = client.post(
        f"/verification/sessions/{verification_id}/selfie",
        data={
            "id_type": "drivers_license",
            "id_number": " ab-123 456 ",
            "date_of_birth": "2000-01-01",
        },
        files={
            "id_image": ("id.jpg", b"id-photo", "image/jpeg"),
            "selfie_image": ("selfie.jpg", b"selfie", "image/jpeg"),
        },
        headers=user["headers"],
    )
    # The face match decides approval; only keyed identity outcomes are persisted.
    assert result.status_code == 200 and result.json()["status"] == "verified"
    record = db.get(IdentityRecord, uuid.UUID(user["account_id"]))
    assert record is not None and record.is_adult
    assert record.id_hmac != b"AB123456"
    assert not hasattr(record, "id_number") and not hasattr(record, "date_of_birth")
    assert client.get("/verification/me", headers=user["headers"]).json()["status"] == "verified"


def test_face_match_below_threshold_rejects_without_identity_record(
    client, db, make_user, monkeypatch
) -> None:
    import app.verification.service as verification_service

    monkeypatch.setattr(verification_service, "compare_faces", lambda *args, **kwargs: 0.79)
    user = make_user("face-mismatch@college.edu")
    session = client.post(
        "/verification/sessions",
        json={"purpose": "responder", "consent": True},
        headers=user["headers"],
    ).json()["id"]
    result = client.post(
        f"/verification/sessions/{session}/selfie",
        data={"id_type": "passport", "id_number": "DEMO-002", "date_of_birth": "2000-01-01"},
        files={
            "id_image": ("id.jpg", b"id-photo", "image/jpeg"),
            "selfie_image": ("selfie.jpg", b"selfie", "image/jpeg"),
        },
        headers=user["headers"],
    )
    assert result.status_code == 200
    assert result.json()["status"] == "rejected"
    assert result.json()["reason_code"] == "face_mismatch"
    assert db.get(IdentityRecord, uuid.UUID(user["account_id"])) is None


def test_invalid_face_image_can_be_corrected_on_the_same_session(
    client, db, make_user, monkeypatch
) -> None:
    import app.verification.service as verification_service

    def invalid_images(*args, **kwargs):
        from app.verification.face_match import FaceMatchError

        raise FaceMatchError("face_image_invalid")

    monkeypatch.setattr(verification_service, "compare_faces", invalid_images)
    user = make_user("retake-photo@college.edu")
    session_id = client.post(
        "/verification/sessions",
        json={"purpose": "responder", "consent": True},
        headers=user["headers"],
    ).json()["id"]
    result = client.post(
        f"/verification/sessions/{session_id}/selfie",
        data={
            "id_type": "passport",
            "id_number": "DEMO-RET-1",
            "date_of_birth": "2000-01-01",
        },
        files={
            "id_image": ("id.jpg", b"id-photo", "image/jpeg"),
            "selfie_image": ("selfie.jpg", b"selfie", "image/jpeg"),
        },
        headers=user["headers"],
    )
    assert result.status_code == 422
    assert result.json()["detail"] == "face_image_invalid"
    assert (
        client.get(
            f"/verification/sessions/{session_id}", headers=user["headers"]
        ).json()["status"]
        == "not_submitted"
    )


def test_expired_unsubmitted_session_is_reported_as_expired(client, db, make_user) -> None:
    user = make_user("expired-draft@college.edu")
    response = client.post(
        "/verification/sessions",
        json={"purpose": "responder", "consent": True},
        headers=user["headers"],
    )
    verification_id = uuid.UUID(response.json()["id"])
    session = db.get(VerificationSession, verification_id)
    assert session is not None
    session.expires_at = datetime.now(UTC) - timedelta(minutes=1)
    db.flush()

    status = client.get(
        f"/verification/sessions/{verification_id}", headers=user["headers"]
    ).json()
    me = client.get("/verification/me", headers=user["headers"]).json()
    assert status["status"] == me["status"] == "expired"
    assert status["reason_code"] == me["reason_code"] == "session_expired"


def test_mock_provider_scenario_requires_server_flag() -> None:
    from datetime import date

    disabled = MockProvider(scenarios_enabled=False, scenario="underage")
    enabled = MockProvider(scenarios_enabled=True, scenario="underage")
    assert disabled.verify("passport", "demo", date(2000, 1, 1)).status == "verified"
    assert enabled.verify("passport", "demo", date(2000, 1, 1)).status == "underage"


def test_unverified_traveller_keeps_checkins_and_sos_alerts(
    client,
    db,
    senders,  # noqa: F811
    clock,  # noqa: F811
    people,  # noqa: F811
) -> None:  # noqa: F811
    owner, asha = people["owner"], people["asha"]
    owner_id = uuid.UUID(owner["account_id"])
    assert db.get(IdentityRecord, owner_id) is None

    journey = start_journey(client, owner, clock)
    checked_in = client.post(
        f"/journeys/{journey}/check-in",
        json={"result": "ok"},
        headers=owner["headers"],
    )
    assert checked_in.status_code == 200
    assert checked_in.json()["state"] == "active"

    visible = client.post(
        f"/journeys/{journey}/sos", json={"covert": False}, headers=owner["headers"]
    )
    assert visible.status_code == 200
    tick(db, senders, clock)
    [visible_alert] = client.get("/escalations/active", headers=asha["headers"]).json()[
        "escalations"
    ]
    assert visible_alert["covert"] is False

    assert (
        client.post(
            f"/escalations/{visible_alert['id']}/resolve", headers=asha["headers"]
        ).status_code
        == 200
    )
    journey = start_journey(client, owner, clock)
    covert = client.post(
        f"/journeys/{journey}/sos", json={"covert": True}, headers=owner["headers"]
    )
    assert covert.status_code == 200
    tick(db, senders, clock)
    [covert_alert] = client.get("/escalations/active", headers=asha["headers"]).json()[
        "escalations"
    ]
    assert covert_alert["covert"] is True
    assert any("silent alarm" in message.title for _, message in senders.push.sent)


def test_eligibility_requires_adult_verified_identity_and_approved_role(
    client, db, make_user
) -> None:
    user = make_user("eligible@college.edu")
    account_id = uuid.UUID(user["account_id"])
    now = datetime(2026, 11, 13, tzinfo=UTC)
    db.add(
        ResponderProfile(
            account_id=account_id,
            role="responder",
            display_name="Riya",
            status="approved",
            applied_at=now,
            approved_at=now,
        )
    )
    db.flush()
    assert not eligible(db, account_id, "responder", now)

    record = IdentityRecord(
        account_id=account_id,
        id_type="drivers_license",
        id_hmac=b"i" * 32,
        person_hmac=b"p" * 32,
        hmac_key_version=1,
        is_adult=True,
        verified_by="mock",
        verified_at=now,
        valid_until=now + timedelta(days=365),
    )
    db.add(record)
    db.flush()
    assert eligible(db, account_id, "responder", now)

    record.is_adult = False
    db.flush()
    assert not eligible(db, account_id, "responder", now)
    record.is_adult = True
    record.valid_until = now
    db.flush()
    assert not eligible(db, account_id, "responder", now)
