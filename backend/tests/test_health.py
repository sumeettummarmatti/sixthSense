from fastapi.testclient import TestClient

from app.main import MODULES, app

client = TestClient(app)


def test_healthz() -> None:
    resp = client.get("/healthz")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok", "service": "core"}


def test_all_modules_mounted() -> None:
    assert len(MODULES) == 15  # verification (p1) + profiles/walks/feedback (p3)
    for module in MODULES:
        assert module.router.prefix.startswith("/")
