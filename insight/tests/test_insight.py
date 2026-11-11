import pathlib

from fastapi.testclient import TestClient

from app.core.config import Settings
from app.main import app
from app.risk.labels import RiskLabel, is_publishable

APP_DIR = pathlib.Path(__file__).resolve().parents[1] / "app"


def test_healthz() -> None:
    resp = TestClient(app).get("/healthz")
    assert resp.status_code == 200
    assert resp.json()["service"] == "insight"


def test_zone_isolation_no_core_settings() -> None:
    """ADR-1: Insight must not know how to reach the Core DB."""
    fields = set(Settings.model_fields)
    assert not any("core" in f for f in fields)


def test_zone_isolation_no_core_imports() -> None:
    for py in APP_DIR.rglob("*.py"):
        text = py.read_text()
        assert "core_database_url" not in text, py
        assert "sixthsense-backend" not in text, py


def test_never_safe_label() -> None:
    assert all("safe" not in label.value.lower() for label in RiskLabel)


def test_publish_threshold() -> None:
    assert not is_publishable(4, 3, 5, 3)
    assert not is_publishable(10, 2, 5, 3)
    assert is_publishable(5, 3, 5, 3)
