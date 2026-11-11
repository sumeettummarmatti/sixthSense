from functools import lru_cache

from redis import Redis

from app.core.config import get_settings


@lru_cache
def get_redis() -> Redis:
    """FastAPI dependency: shared Redis client for ephemeral state (codes, nonces, tokens)."""
    return Redis.from_url(get_settings().redis_url)
