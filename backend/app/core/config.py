from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Core-zone settings. The Core service never receives Insight DB credentials (ADR-1)."""

    model_config = SettingsConfigDict(env_file=("../.env", ".env"), extra="ignore")

    env: str = "dev"
    core_database_url: str = (
        "postgresql+psycopg://core:core_dev_password@localhost:5434/sixthsense_core"
    )
    redis_url: str = "redis://localhost:6379/0"
    nats_url: str = "nats://localhost:4222"


@lru_cache
def get_settings() -> Settings:
    return Settings()
