"""Live location and audio relay (P2-W5, P2-W2-encrypted-audio-relay): one WebSocket,
ciphertext only.

Protocol (JSON text frames):
  phone -> server  {"type": "auth", "access_token": "..."}          first message, within 10 s
                   {"type": "location", "envelopes": [<P1-W6 envelope>, ...]}   traveller only
                   {"type": "audio", "envelopes": [...]}   traveller only, 5 s voice clips
                   {"type": "ping"}
  server -> phone  {"type": "ready"}
                   {"type": "location", "envelope": {...},
                    "sender": {"key_id": "...", "ed25519_public_key": "..."}}
                   {"type": "audio", "envelope": {...}, "sender": {...}}
                   {"type": "sent", "delivered": n, "offline": n, "not_allowed": n}
                   {"type": "pong"} | {"type": "error", "detail": "..."}
The token goes in the first message, not the URL, so it never lands in access logs. It is
re-checked on every message; when it expires the socket closes with 4401 and the app reconnects
with a fresh token. Contacts receive only during the traveller's open journey or alert (rule 4).

Location is never stored. Audio clips for a listener who is offline are kept as ciphertext the
server cannot read, in Redis only, for 24 h at most (the last 30 min of clips), and dropped
unread once that listener may no longer hear the traveller (alert closed, escort over).
"""

import asyncio
import json
import logging
import time
from collections import deque
from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, WebSocket, WebSocketDisconnect
from starlette.concurrency import run_in_threadpool

from app.core.config import Settings, get_settings
from app.core.db import get_session_factory
from app.core.redis import get_redis
from app.identity.router import CurrentSession, session_from_token
from app.relay.hub import hub
from app.relay.routing import RelayError, may_still_hear, route, route_audio

router = APIRouter(prefix="/relay", tags=["relay"])
log = logging.getLogger(__name__)

AUTH_TIMEOUT_SECONDS = 10
RATE_WINDOW_SECONDS = 5
RATE_MAX_MESSAGES = 10  # a location every ~0.5 s at most
CLOSE_UNAUTHENTICATED = 4401
AUDIO_RATE_WINDOW_SECONDS = 20
AUDIO_RATE_MAX_MESSAGES = 8  # one clip every 5 s, with room for a catch-up burst
PENDING_KEY = "relay:pending:{device_id}"
PENDING_MAX_CLIPS = 360  # 30 minutes of 5 s clips
PENDING_TTL_SECONDS = 24 * 3600


class _RateLimit:
    def __init__(self, window: float = RATE_WINDOW_SECONDS, limit: int = RATE_MAX_MESSAGES) -> None:
        self._times: deque[float] = deque()
        self._window = window
        self._limit = limit

    def allow(self) -> bool:
        now = time.monotonic()
        while self._times and now - self._times[0] > self._window:
            self._times.popleft()
        if len(self._times) >= self._limit:
            return False
        self._times.append(now)
        return True


@router.websocket("/ws")
async def relay(
    socket: WebSocket,
    settings: Annotated[Settings, Depends(get_settings)],
    redis=Depends(get_redis),  # noqa: B008
    session_factory=Depends(get_session_factory),  # noqa: B008
) -> None:
    await socket.accept()
    try:
        first = await asyncio.wait_for(socket.receive_json(), AUTH_TIMEOUT_SECONDS)
    except (TimeoutError, WebSocketDisconnect, ValueError):
        await socket.close(CLOSE_UNAUTHENTICATED)
        return
    token = first.get("access_token", "") if isinstance(first, dict) else ""
    session = await run_in_threadpool(session_from_token, settings, redis, token)
    if first.get("type") != "auth" or session is None:
        await socket.close(CLOSE_UNAUTHENTICATED)
        return

    await hub.add(session.device_id, socket)
    limit = _RateLimit()
    audio_limit = _RateLimit(AUDIO_RATE_WINDOW_SECONDS, AUDIO_RATE_MAX_MESSAGES)
    try:
        await socket.send_json({"type": "ready"})
        await _deliver_pending(socket, session, session_factory, redis)
        while True:
            try:
                message = await socket.receive_json()
            except ValueError:
                await socket.send_json({"type": "error", "detail": "bad_json"})
                continue
            if await run_in_threadpool(session_from_token, settings, redis, token) != session:
                await socket.send_json({"type": "error", "detail": "token_expired"})
                await socket.close(CLOSE_UNAUTHENTICATED)
                return
            kind = message.get("type") if isinstance(message, dict) else None
            if kind == "ping":
                await socket.send_json({"type": "pong"})
            elif kind == "location":
                if not limit.allow():
                    await socket.send_json({"type": "error", "detail": "rate_limited"})
                    continue
                await _relay_location(socket, session, session_factory, message)
            elif kind == "audio":
                if not audio_limit.allow():
                    await socket.send_json({"type": "error", "detail": "rate_limited"})
                    continue
                await _relay_audio(socket, session, session_factory, redis, message)
            else:
                await socket.send_json({"type": "error", "detail": "unknown_type"})
    except WebSocketDisconnect:
        pass
    finally:
        await hub.remove(session.device_id, socket)


async def _relay_location(socket: WebSocket, sender: CurrentSession, session_factory, message):
    def _route():
        with session_factory() as db:
            return route(db, sender, message.get("envelopes"))

    try:
        routed = await run_in_threadpool(_route)
    except RelayError as exc:
        await socket.send_json({"type": "error", "detail": str(exc)})
        return
    delivered = 0
    for device_id, frame in routed.deliveries:
        delivered += await hub.deliver(device_id, frame)
    await socket.send_json(
        {
            "type": "sent",
            "delivered": delivered,
            "offline": len(routed.deliveries) - delivered,
            "not_allowed": routed.not_allowed,
        }
    )


async def _relay_audio(
    socket: WebSocket, sender: CurrentSession, session_factory, redis, message
) -> None:
    def _route():
        with session_factory() as db:
            return route_audio(db, sender, message.get("envelopes"), datetime.now(UTC))

    try:
        routed = await run_in_threadpool(_route)
    except RelayError as exc:
        await socket.send_json({"type": "error", "detail": str(exc)})
        return
    delivered = 0
    offline: list[tuple] = []
    for device_id, frame in routed.deliveries:
        if await hub.deliver(device_id, frame):
            delivered += 1
        else:
            offline.append((device_id, frame))
    if offline:
        await run_in_threadpool(_queue, redis, offline)
    await socket.send_json(
        {
            "type": "sent",
            "delivered": delivered,
            "offline": len(offline),
            "not_allowed": routed.not_allowed,
        }
    )


def _queue(redis, offline) -> None:
    pipe = redis.pipeline()
    for device_id, frame in offline:
        key = PENDING_KEY.format(device_id=device_id)
        pipe.rpush(key, json.dumps(frame))
        pipe.ltrim(key, -PENDING_MAX_CLIPS, -1)
        pipe.expire(key, PENDING_TTL_SECONDS)
    pipe.execute()


async def _deliver_pending(socket: WebSocket, session: CurrentSession, session_factory, redis):
    """Hand a reconnecting listener the clips they missed, if they may still hear them."""

    def _take():
        key = PENDING_KEY.format(device_id=session.device_id)
        pipe = redis.pipeline()
        pipe.lrange(key, 0, -1)
        pipe.delete(key)
        raw = pipe.execute()[0]
        if not raw:
            return []
        frames = [json.loads(item) for item in raw]
        now = datetime.now(UTC)
        allowed: dict[str, bool] = {}
        with session_factory() as db:
            for frame in frames:
                journey_id = frame["envelope"]["session_id"]
                if journey_id not in allowed:
                    allowed[journey_id] = may_still_hear(db, journey_id, session.account_id, now)
        return [frame for frame in frames if allowed[frame["envelope"]["session_id"]]]

    for frame in await run_in_threadpool(_take):
        await socket.send_json(frame)
