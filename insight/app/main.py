from fastapi import FastAPI

from app import clustering, reports, risk, routing
from app.core.logging import configure_logging

MODULES = [reports, clustering, risk, routing]


def create_app() -> FastAPI:
    configure_logging()
    app = FastAPI(title="SixthSense Insight API", version="0.1.0")

    @app.get("/healthz", tags=["ops"])
    def healthz() -> dict[str, str]:
        return {"status": "ok", "service": "insight"}

    for module in MODULES:
        app.include_router(module.router)
    return app


app = create_app()
