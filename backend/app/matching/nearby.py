"""Nearby responders (F6, campus pilot): who is on duty near an SOS, and asking them to help.

Privacy (rules 2 and 4):
- On-duty phones send a rough area (rounded to ~110 m), kept in Redis for 5 minutes, then gone.
  No history, nothing in Postgres.
- During a full alert the traveller's phone sends its rough area too (10 minutes TTL).
- Responders see only "~350 m away" until they say "I'm going". Then the traveller's phone adds
  them to its end-to-end encrypted live location (the server never sees coordinates).
- Only SOS / full alerts reach responders, never a single missed check-in.
"""

import json
import logging
import math
import uuid
from dataclasses import dataclass
from datetime import datetime

from redis import Redis
from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.core import audit
from app.core.config import Settings
from app.escalation.models import Escalation, EscalationRecipient
from app.journey.state import State
from app.matching.models import ResponderOffer, ResponderProfile
from app.notification.channels import Message, Senders
from app.verification.eligibility import eligible

log = logging.getLogger(__name__)

_PRESENCE = "responders:presence"  # hash: account id -> {"lat", "lng", "at"}
_AREA = "alert:area:{journey_id}"
WALK_METERS_PER_MINUTE = 75  # ~4.5 km/h


@dataclass(frozen=True)
class Area:
    latitude: float
    longitude: float


def rough(latitude: float, longitude: float) -> Area:
    """Round to 3 decimals (~110 m). Never trust the phone to have done it."""
    return Area(round(latitude, 3), round(longitude, 3))


def distance_m(a: Area, b: Area) -> int:
    """Great-circle distance in metres."""
    lat1, lat2 = math.radians(a.latitude), math.radians(b.latitude)
    dlat = lat2 - lat1
    dlng = math.radians(b.longitude - a.longitude)
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlng / 2) ** 2
    return round(2 * 6_371_000 * math.asin(math.sqrt(h)))


def walk_minutes(meters: int) -> int:
    return max(1, math.ceil(meters / WALK_METERS_PER_MINUTE))


# --- presence ------------------------------------------------------------------------------


def set_presence(redis: Redis, account_id: uuid.UUID, area: Area, now: datetime) -> None:
    redis.hset(
        _PRESENCE,
        str(account_id),
        json.dumps({"lat": area.latitude, "lng": area.longitude, "at": now.timestamp()}),
    )


def clear_presence(redis: Redis, account_id: uuid.UUID) -> None:
    redis.hdel(_PRESENCE, str(account_id))


def presence_of(
    redis: Redis, account_id: uuid.UUID, settings: Settings, now: datetime
) -> Area | None:
    raw = redis.hget(_PRESENCE, str(account_id))
    return _fresh(raw, settings, now)


def _fresh(raw: bytes | str | None, settings: Settings, now: datetime) -> Area | None:
    if raw is None:
        return None
    item = json.loads(raw)
    if now.timestamp() - item["at"] > settings.responder_presence_ttl_seconds:
        return None
    return Area(item["lat"], item["lng"])


def on_duty(redis: Redis, settings: Settings, now: datetime) -> dict[uuid.UUID, Area]:
    """Fresh on-duty areas; stale entries are dropped as we go."""
    fresh, stale = {}, []
    for key, raw in redis.hgetall(_PRESENCE).items():
        area = _fresh(raw, settings, now)
        account = key.decode() if isinstance(key, bytes) else key
        if area is None:
            stale.append(account)
        else:
            fresh[uuid.UUID(account)] = area
    if stale:
        redis.hdel(_PRESENCE, *stale)
    return fresh


# --- the traveller's rough area during a full alert ----------------------------------------


def set_alert_area(redis: Redis, journey_id: uuid.UUID, area: Area, settings: Settings) -> None:
    redis.set(
        _AREA.format(journey_id=journey_id),
        json.dumps({"lat": area.latitude, "lng": area.longitude}),
        ex=settings.alert_area_ttl_seconds,
    )


def alert_area(redis: Redis, journey_id: uuid.UUID | None) -> Area | None:
    if journey_id is None:
        return None
    raw = redis.get(_AREA.format(journey_id=journey_id))
    if raw is None:
        return None
    item = json.loads(raw)
    return Area(item["lat"], item["lng"])


def clear_alert_area(redis: Redis, journey_id: uuid.UUID) -> None:
    redis.delete(_AREA.format(journey_id=journey_id))


# --- matching ------------------------------------------------------------------------------


def radius_for(escalation: Escalation, settings: Settings, now: datetime) -> int:
    """500 m first; one step wider every minute nobody has said "I'm going"."""
    steps = int(
        (now - escalation.opened_at).total_seconds() // settings.responder_radius_step_seconds
    )
    radii = settings.responder_radii_m
    return radii[min(steps, len(radii) - 1)]


def offer_message(meters: int, covert: bool) -> Message:
    body = (
        f"Someone about {meters} m from you (~{walk_minutes(meters)} min walk) asked for help. "
        "Open SixthSense > Respond to see where and say if you can go."
    )
    if covert:
        body += " It is a silent alarm: do not shout or call out, approach calmly."
    body += " If anyone is in danger, call 112."
    return Message("SixthSense: someone nearby needs help", body)


def dispatch(db: Session, redis: Redis, senders: Senders, settings: Settings, now: datetime) -> int:
    """Ask the nearest on-duty responders to help with each open full alert. Returns how many
    new people were asked. Runs every few seconds; idempotent (one offer per pair)."""
    escalations = list(
        db.scalars(
            select(Escalation).where(
                Escalation.closed_at.is_(None), Escalation.level == State.FULL_ESCALATION.value
            )
        )
    )
    if not escalations:
        return 0
    duty = on_duty(redis, settings, now)
    if not duty:
        return 0
    approved = set(
        db.scalars(
            select(ResponderProfile.account_id).where(
                ResponderProfile.status == "approved",
                ResponderProfile.account_id.in_(list(duty)),
            )
        )
    )
    approved = {account for account in approved if eligible(db, account, "responder", now)}
    asked = 0
    for escalation in escalations:
        area = alert_area(redis, escalation.journey_id)
        if area is None:
            continue
        offers = list(
            db.scalars(select(ResponderOffer).where(ResponderOffer.escalation_id == escalation.id))
        )
        going = sum(1 for offer in offers if offer.status == "going")
        if (
            going >= settings.responder_precise_limit
            or len(offers) >= settings.responder_max_offers
        ):
            continue
        already = {offer.responder_id for offer in offers}
        contacts = set(
            db.scalars(
                select(EscalationRecipient.contact_account_id).where(
                    EscalationRecipient.escalation_id == escalation.id
                )
            )
        )
        radius = radius_for(escalation, settings, now)
        candidates = sorted(
            (
                (distance_m(area, duty[account]), account)
                for account in approved
                if account not in already
                and account not in contacts  # they are already alerted as contacts
                and account != escalation.owner_id
            ),
        )
        room = settings.responder_max_offers - len(offers)
        for meters, account in [c for c in candidates if c[0] <= radius][:room]:
            new_id = db.scalar(
                insert(ResponderOffer)
                .values(
                    escalation_id=escalation.id,
                    responder_id=account,
                    distance_m=meters,
                    offered_at=now,
                )
                .on_conflict_do_nothing(constraint="uq_responder_offers_pair")
                .returning(ResponderOffer.id)
            )
            if new_id is None:
                continue
            asked += 1
            audit.record(
                db, "responder.offered", actor=escalation.owner_id, target=f"offer:{new_id}"
            )
            _notify(db, senders, account, offer_message(meters, escalation.covert))
    db.commit()
    if asked:
        log.info("asked %d nearby responders", asked)
    return asked


def _notify(db: Session, senders: Senders, account: uuid.UUID, message: Message) -> None:
    # Imported here: the ladder module imports this one's neighbours at load time.
    from app.escalation.ladder import _deliver

    for channel in ("push", "telegram"):
        if _deliver(db, senders, channel, account, message):
            return


def going_count(db: Session, escalation_id: uuid.UUID) -> int:
    return (
        db.scalar(
            select(func.count())
            .select_from(ResponderOffer)
            .where(ResponderOffer.escalation_id == escalation_id, ResponderOffer.status == "going")
        )
        or 0
    )


@dataclass(frozen=True)
class Search:
    """What the traveller sees during a full alert: counts only, never who or where."""

    radius_m: int
    on_duty_nearby: int
    asked: int
    going: int


def search_summary(
    db: Session, redis: Redis, settings: Settings, escalation: Escalation, now: datetime
) -> Search:
    radius = radius_for(escalation, settings, now)
    offers = list(
        db.scalars(select(ResponderOffer).where(ResponderOffer.escalation_id == escalation.id))
    )
    area = alert_area(redis, escalation.journey_id)
    nearby_count = 0
    if area is not None:
        duty = on_duty(redis, settings, now)
        contacts = set(
            db.scalars(
                select(EscalationRecipient.contact_account_id).where(
                    EscalationRecipient.escalation_id == escalation.id
                )
            )
        )
        approved = set(
            db.scalars(
                select(ResponderProfile.account_id).where(
                    ResponderProfile.status == "approved",
                    ResponderProfile.account_id.in_(list(duty)),
                )
            )
        )
        nearby_count = sum(
            1
            for account in approved - contacts - {escalation.owner_id}
            if distance_m(area, duty[account]) <= radius
        )
    return Search(
        radius_m=radius,
        on_duty_nearby=nearby_count,
        asked=sum(1 for offer in offers if offer.status != "declined"),
        going=sum(1 for offer in offers if offer.status == "going"),
    )
