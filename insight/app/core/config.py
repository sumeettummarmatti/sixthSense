from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


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


@lru_cache
def get_settings() -> Settings:
    return Settings()
