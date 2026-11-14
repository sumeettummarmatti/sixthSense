"""Background worker (Arq on Redis). Run it next to the API:

    cd backend && uv run arq app.worker.WorkerSettings

Every 5 seconds: advance quiet journeys (watchdog), open/close escalations, send due alerts,
send all-clears, ask nearby responders
about full alerts, and link Telegram chats. Every night: drop expired journeys and escalations.
"""

import asyncio
import logging
from datetime import UTC, datetime

from arq import cron
from arq.connections import RedisSettings

from app.core.config import get_settings
from app.core.db import SessionLocal
from app.core.logging import configure_logging
from app.core.redis import get_redis
from app.escalation import ladder
from app.journey import service as journeys
from app.matching import nearby
from app.notification.channels import get_senders
from app.notification.router import link_telegram_chats

log = logging.getLogger(__name__)


def tick(now: datetime | None = None) -> dict[str, int]:
    """One pass of the safety loop. Safe to run concurrently: rows are locked or idempotent."""
    now = now or datetime.now(UTC)
    settings, senders = get_settings(), get_senders()
    with SessionLocal() as db:
        escalated = journeys.run_watchdog(db, now)
        closed = ladder.sync(db, settings, now)
        sent = ladder.send_due(db, senders, settings, now)
        ladder.send_all_clear(db, senders, closed)
        asked = nearby.dispatch(db, get_redis(), senders, settings, now)
        linked = link_telegram_chats(db, get_redis(), settings, senders)
    return {
        "escalated": len(escalated),
        "closed": len(closed),
        "sent": sent,
        "asked": asked,
        "linked": linked,
    }


def nightly(now: datetime | None = None) -> dict[str, int]:
    now = now or datetime.now(UTC)
    with SessionLocal() as db:
        return {
            "journeys": journeys.purge_expired(db, now),
            "escalations": ladder.purge_expired(db, now),
        }


async def _tick(ctx: dict) -> None:
    # tick() is blocking (DB + Telegram calls). Run it in a thread so the worker's Redis
    # heartbeat keeps running; on slow Wi-Fi a blocked loop made Redis time out and crash.
    result = await asyncio.to_thread(tick)
    if any(result.values()):
        log.info("tick %s", result)


async def _nightly(ctx: dict) -> None:
    log.info("purge %s", await asyncio.to_thread(nightly))


async def _startup(ctx: dict) -> None:
    configure_logging()


class WorkerSettings:
    redis_settings = RedisSettings.from_dsn(get_settings().redis_url)
    redis_settings.conn_timeout = 5
    on_startup = _startup
    cron_jobs = [
        cron(_tick, second=set(range(0, 60, 5)), run_at_startup=True, unique=True, timeout=30),
        cron(_nightly, hour={3}, minute={0}, unique=True),
    ]
    functions: list = []
