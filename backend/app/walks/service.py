"""Walk With Me rules: companion presence, the traveller's rough area, handshake codes, and
keeping walk state consistent with the journey (lazy expiry, end when the journey ends)."""

import json
import uuid
from datetime import datetime

from redis import Redis
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core import audit
from app.core.config import Settings
from app.feedback.models import Feedback
from app.identity import security
from app.journey.models import Journey
from app.journey.state import State
from app.matching import nearby
from app.walks.models import CompanionProfile, Walk

_PRESENCE = "companions:presence"  # hash: account id -> {"lat", "lng", "at"}
_AREA = "walk:area:{walk_id}"
OPEN = ("requested", "accepted")


# --- companion presence (same pattern as responders, separate hash) -----------------------


def set_presence(redis: Redis, account_id: uuid.UUID, area: nearby.Area, now: datetime) -> None:
    redis.hset(
        _PRESENCE,
        str(account_id),
        json.dumps({"lat": area.latitude, "lng": area.longitude, "at": now.timestamp()}),
    )


def clear_presence(redis: Redis, account_id: uuid.UUID) -> None:
    redis.hdel(_PRESENCE, str(account_id))


def _fresh(raw, settings: Settings, now: datetime) -> nearby.Area | None:
    if raw is None:
        return None
    item = json.loads(raw)
    if now.timestamp() - item["at"] > settings.companion_presence_ttl_seconds:
        return None
    return nearby.Area(item["lat"], item["lng"])


def presence_of(
    redis: Redis, account_id: uuid.UUID, settings: Settings, now: datetime
) -> nearby.Area | None:
    return _fresh(redis.hget(_PRESENCE, str(account_id)), settings, now)


def available(redis: Redis, settings: Settings, now: datetime) -> dict[uuid.UUID, nearby.Area]:
    fresh, stale = {}, []
    for key, raw in redis.hgetall(_PRESENCE).items():
        account = key.decode() if isinstance(key, bytes) else key
        area = _fresh(raw, settings, now)
        if area is None:
            stale.append(account)
        else:
            fresh[uuid.UUID(account)] = area
    if stale:
        redis.hdel(_PRESENCE, *stale)
    return fresh


# --- the traveller's rough area, only while the walk is open ------------------------------


def set_area(redis: Redis, walk_id: uuid.UUID, area: nearby.Area, settings: Settings) -> None:
    redis.set(
        _AREA.format(walk_id=walk_id),
        json.dumps({"lat": area.latitude, "lng": area.longitude}),
        ex=settings.walk_area_ttl_seconds,
    )


def area_of(redis: Redis, walk_id: uuid.UUID) -> nearby.Area | None:
    raw = redis.get(_AREA.format(walk_id=walk_id))
    if raw is None:
        return None
    item = json.loads(raw)
    return nearby.Area(item["lat"], item["lng"])


def clear_area(redis: Redis, walk_id: uuid.UUID) -> None:
    redis.delete(_AREA.format(walk_id=walk_id))


# --- rules ---------------------------------------------------------------------------------


def handshake_code(settings: Settings, walk_id: uuid.UUID) -> str:
    """Same 4 digits on both phones, derived from the walk id: nothing extra stored."""
    digest = security.keyed_hash(settings.token_secret, "walk-handshake", str(walk_id))
    return f"{int(digest[:8], 16) % 10000:04d}"


def revoke_companion(db: Session, redis: Redis, account_id: uuid.UUID, now: datetime) -> bool:
    """Remove someone as a companion (after a complaint): no longer findable, open requests to
    them are declined and an accepted walk ends now, which stops the live location relay.
    The caller commits."""
    profile = db.get(CompanionProfile, account_id)
    if profile is None:
        return False
    clear_presence(redis, account_id)
    profile.status = "revoked"
    for walk in db.scalars(
        select(Walk).where(Walk.companion_id == account_id, Walk.status.in_(OPEN))
    ):
        if walk.status == "accepted":
            end(db, redis, walk, "companion_revoked", now)
        else:
            walk.status, walk.responded_at = "declined", now
            clear_area(redis, walk.id)
    audit.record(db, "companion.revoked", target=f"account:{account_id}")
    return True


def rating_of(db: Session, companion_id: uuid.UUID) -> tuple[float | None, int]:
    avg, count = db.execute(
        select(func.avg(Feedback.companion_stars), func.count(Feedback.companion_stars))
        .join(Walk, Walk.id == Feedback.walk_id)
        .where(Walk.companion_id == companion_id, Feedback.companion_stars.is_not(None))
    ).one()
    return (round(float(avg), 1) if avg is not None else None), count or 0


def refresh(db: Session, redis: Redis, walk: Walk, now: datetime) -> Walk:
    """Expire unanswered requests; end a walk whose journey is over."""
    if walk.status == "requested" and now >= walk.expires_at:
        walk.status = "expired"
        audit.record(db, "walk.expired", actor=walk.traveller_id, target=f"walk:{walk.id}")
        clear_area(redis, walk.id)
    elif walk.status == "accepted":
        journey = db.get(Journey, walk.journey_id)
        if journey is None or journey.state == State.RESOLVED:
            end(db, redis, walk, "journey_over", now)
    return walk


def end(db: Session, redis: Redis, walk: Walk, reason: str, now: datetime) -> None:
    walk.status, walk.ended_at, walk.end_reason = "ended", now, reason
    audit.record(db, f"walk.ended.{reason}", actor=walk.traveller_id, target=f"walk:{walk.id}")
    clear_area(redis, walk.id)


def open_walks_of(db: Session, account_id: uuid.UUID) -> list[Walk]:
    return list(
        db.scalars(
            select(Walk)
            .where(
                Walk.status.in_(OPEN),
                (Walk.traveller_id == account_id) | (Walk.companion_id == account_id),
            )
            .order_by(Walk.requested_at)
        )
    )


def accepted_walk_for_journey(db: Session, journey_id: uuid.UUID) -> Walk | None:
    return db.scalars(
        select(Walk).where(Walk.journey_id == journey_id, Walk.status == "accepted")
    ).first()


def accepted_walk(db: Session, walk_id: uuid.UUID) -> Walk | None:
    walk = db.get(Walk, walk_id)
    if walk is None or walk.status != "accepted":
        return None
    journey = db.get(Journey, walk.journey_id)
    if journey is None or journey.state == State.RESOLVED:
        return None
    return walk


def accepted_walk_for_companion(db: Session, companion_id: uuid.UUID) -> Walk | None:
    return db.scalars(
        select(Walk).where(Walk.companion_id == companion_id, Walk.status == "accepted")
    ).first()
