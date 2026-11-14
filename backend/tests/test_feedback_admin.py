# ruff: noqa: F811  (pytest fixtures imported from other test modules)
"""Admin feedback page (P2-W3-feedback-admin-page): login, table, summary, CSV download."""

import csv
import io

import pytest
from sqlalchemy import select
from test_feedback import journey, post  # noqa: F401  (fixture)

from app.core.audit import AuditEvent
from app.core.config import Settings, get_settings
from app.main import app

ADMIN = ("admin", "a-long-test-admin-password")


@pytest.fixture
def admin_on(client):
    app.dependency_overrides[get_settings] = lambda: Settings(
        admin_username=ADMIN[0], admin_password=ADMIN[1]
    )
    return client


def test_page_is_off_without_an_admin_password(client) -> None:
    app.dependency_overrides[get_settings] = lambda: Settings(admin_password="")
    assert client.get("/admin/feedback", auth=ADMIN).status_code == 404
    assert client.get("/admin/feedback/export.csv", auth=ADMIN).status_code == 404


def test_wrong_or_missing_login_is_refused_and_audited(admin_on, db) -> None:
    resp = admin_on.get("/admin/feedback")
    assert resp.status_code == 401 and resp.headers["www-authenticate"].startswith("Basic")
    assert admin_on.get("/admin/feedback", auth=("admin", "wrong")).status_code == 401
    assert admin_on.get("/admin/feedback/export.csv", auth=("x", ADMIN[1])).status_code == 401
    failed = db.scalars(
        select(AuditEvent).where(AuditEvent.action == "feedback.admin_login_failed")
    ).all()
    assert len(failed) == 3 and all(e.target is None for e in failed)  # no usernames logged


def test_page_shows_every_rating_escaped_with_summary(admin_on, db, journey) -> None:
    post(
        admin_on,
        journey,
        journey_id=journey["journey"],
        route_stars=2,
        chips=["felt_uneasy"],
        note="<script>alert(1)</script> dark lane",
    )
    resp = admin_on.get("/admin/feedback", auth=ADMIN)
    assert resp.status_code == 200 and resp.headers["content-type"].startswith("text/html")
    assert resp.headers["cache-control"] == "no-store"
    assert "noindex" in resp.headers["x-robots-tag"]
    body = resp.text
    assert "<script>alert(1)</script>" not in body
    assert "&lt;script&gt;alert(1)&lt;/script&gt; dark lane" in body
    assert "felt_uneasy" in body and journey["journey"] in body
    assert "export.csv" in body
    assert db.scalars(select(AuditEvent).where(AuditEvent.action == "feedback.admin_view")).one()


def test_csv_download_has_every_column_and_is_audited(admin_on, db, journey) -> None:
    post(admin_on, journey, journey_id=journey["journey"], route_stars=5, chips=["well_lit"])
    resp = admin_on.get("/admin/feedback/export.csv", auth=ADMIN)
    assert resp.status_code == 200 and resp.headers["content-type"].startswith("text/csv")
    assert "attachment" in resp.headers["content-disposition"]
    [row] = list(csv.DictReader(io.StringIO(resp.text)))
    assert row["route_stars"] == "5" and row["chips"] == "well_lit"
    assert row["journey_id"] == journey["journey"] and row["companion_stars"] == ""
    event = db.scalars(select(AuditEvent).where(AuditEvent.action == "feedback.admin_export")).one()
    assert event.target == "rows:1"


def test_admin_password_must_be_long_outside_dev() -> None:
    real = {
        name: "x" * 48
        for name in (
            "otp_pepper",
            "token_secret",
            "data_key",
            "alert_signing_key",
            "identity_hmac_secret",
            "face_template_key",
        )
    }
    with pytest.raises(ValueError, match="ADMIN_PASSWORD"):
        Settings(env="staging", admin_username="admin", admin_password="short", **real)
    Settings(env="staging", admin_username="admin", admin_password="y" * 16, **real)
