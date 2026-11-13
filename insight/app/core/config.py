from functools import lru_cache

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

_DEV_SECRET_PREFIX = "dev-only-"  # noqa: S105  (marker, not a secret)


class Settings(BaseSettings):
    """Insight-zone settings.

    ADR-1: this service must NEVER hold Core DB credentials or user identifiers.
    Only the insight DB URL is read; CORE_* env vars are ignored.
    """

    model_config = SettingsConfigDict(env_file=("../.env", ".env"), extra="ignore")

    env: str = "dev"
    insight_database_url: str = (
        "postgresql+psycopg://insight:insight_dev_password@localhost:5433/sixthsense_insight"
    )
    # Publish threshold: a cluster stays hidden until >= k reports from >= m distinct devices.
    publish_min_reports: int = 5
    publish_min_devices: int = 3

    # Routes (P4-W1-demo-safe-routes). Engine: "osrm" (public server, no key; dev default) or
    # "valhalla" (local, routing-engine/). The area file is public infrastructure data built by
    # scripts/build_area_features.py; the path is relative to insight/.
    routing_provider: str = "osrm"
    # FOSSGIS walking router (free, real foot profile). router.project-osrm.org only does car
    # routing whatever profile is asked, which gave car routes and driving times.
    osrm_base_url: str = "https://routing.openstreetmap.de/routed-foot"
    valhalla_base_url: str = "http://localhost:8002"
    routes_area_file: str = "data/areas/indiranagar.json"
    routes_max_detour_ratio: float = 1.25  # a recommended route is at most 25% longer...
    routes_max_detour_m: int = 600  # ...and never more than 600 m longer than the shortest
    routes_demo_page: bool = True  # serves /routes/demo (a map page for demos)

    # Place reports feeding routes: ~55 m cells, HMAC'd reporter token, time-limited evidence.
    report_pepper: str = "dev-only-report-pepper-change-me"
    report_ttl_days: int = 90
    report_half_life_days: float = 30
    reports_per_hour: int = 20  # per reporter token

    @model_validator(mode="after")
    def _no_dev_secrets_outside_dev(self) -> "Settings":
        if self.env not in ("dev", "test") and self.report_pepper.startswith(_DEV_SECRET_PREFIX):
            raise ValueError(f"REPORT_PEPPER must be a real secret when ENV={self.env}")
        return self


@lru_cache
def get_settings() -> Settings:
    return Settings()
