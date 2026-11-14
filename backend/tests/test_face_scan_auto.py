"""FACE_CHECK_PROVIDER=auto (P3-W4-face-scan-auto): real match when a face template exists."""

import uuid
from datetime import UTC, datetime

import pytest
from fastapi import HTTPException
from sqlalchemy import select

from app.core.audit import AuditEvent
from app.core.config import Settings
from app.face_scan import service as face_scan
from app.verification.models import FaceTemplate

NOW = datetime(2026, 11, 15, 12, 0, tzinfo=UTC)


def _check(db, account_id):
    face_scan.check(
        db,
        Settings(face_check_provider="auto"),
        account_id,
        "responder",
        b"\xff\xd8\xffselfie",
        "image/jpeg",
        NOW,
        target="offer:x",
    )


def _actions(db) -> set[str]:
    return set(db.scalars(select(AuditEvent.action)))


def test_auto_matches_against_the_saved_template(db, make_user, monkeypatch) -> None:
    account = uuid.UUID(make_user("tpl@college.edu")["account_id"])
    db.add(
        FaceTemplate(
            account_id=account,
            embedding_enc=b"x",
            calculator_version="facenet.Calculator",
            consent_version="walk-face-template-v1",
            consent_at=NOW,
        )
    )
    db.flush()
    calls = []
    monkeypatch.setattr(
        face_scan, "check_walk_selfie", lambda *a, **k: calls.append(a) or False
    )
    with pytest.raises(HTTPException) as exc:
        _check(db, account)
    assert exc.value.status_code == 403 and exc.value.detail == "face_mismatch"
    assert calls and "responder.face_scan.failed.auto" in _actions(db)


def test_auto_without_a_template_falls_back_to_the_phone_check(
    db, make_user, monkeypatch
) -> None:
    account = uuid.UUID(make_user("notpl@college.edu")["account_id"])
    monkeypatch.setattr(
        face_scan, "check_walk_selfie", lambda *a, **k: pytest.fail("no template to match")
    )
    _check(db, account)
    assert "responder.face_scan.passed.auto_device" in _actions(db)
