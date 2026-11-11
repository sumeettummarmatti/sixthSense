from fastapi import FastAPI

from app import (
    comms,
    escalation,
    identity,
    journey,
    matching,
    notification,
    relay,
    routing,
    trust_safety,
    walks,
)
from app.core.logging import configure_logging

MODULES = [
    identity,
    journey,
    escalation,
    notification,
    matching,
    walks,
    relay,
    comms,
    routing,
    trust_safety,
]


def create_app() -> FastAPI:
    configure_logging()
    app = FastAPI(title="SixthSense Core API", version="0.1.0")

    @app.get("/healthz", tags=["ops"])
    def healthz() -> dict[str, str]:
        return {"status": "ok", "service": "core"}

    for module in MODULES:
        app.include_router(module.router)
    return app


app = create_app()
