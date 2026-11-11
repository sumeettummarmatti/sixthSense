"""Background worker (Arq on Redis). Run it next to the API:

    cd backend && uv run arq app.worker.WorkerSettings

Every 5 seconds: advance quiet journeys (watchdog), open/close escalations, send due alerts,
send all-clears, and link Telegram chats. Every night: drop expired journeys and escalations.
"""

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
        linked = link_telegram_chats(db, get_redis(), settings, senders)
    return {"escalated": len(escalated), "closed": len(closed), "sent": sent, "linked": linked}


def nightly(now: datetime | None = None) -> dict[str, int]:
    now = now or datetime.now(UTC)
    with SessionLocal() as db:
        return {
            "journeys": journeys.purge_expired(db, now),
            "escalations": ladder.purge_expired(db, now),
        }


async def _tick(ctx: dict) -> None:
    result = tick()
    if any(result.values()):
        log.info("tick %s", result)


async def _nightly(ctx: dict) -> None:
    log.info("purge %s", nightly())


async def _startup(ctx: dict) -> None:
    configure_logging()


class WorkerSettings:
    redis_settings = RedisSettings.from_dsn(get_settings().redis_url)
    on_startup = _startup
    cron_jobs = [
        cron(_tick, second=set(range(0, 60, 5)), run_at_startup=True, unique=True, timeout=30),
        cron(_nightly, hour={3}, minute={0}, unique=True),
    ]
    functions: list = []
