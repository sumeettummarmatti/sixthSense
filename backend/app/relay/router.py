"""Live location relay (P2-W5): one WebSocket, ciphertext only, nothing stored.

Protocol (JSON text frames):
  phone -> server  {"type": "auth", "access_token": "..."}          first message, within 10 s
                   {"type": "location", "envelopes": [<P1-W6 envelope>, ...]}   traveller only
                   {"type": "ping"}
  server -> phone  {"type": "ready"}
                   {"type": "location", "envelope": {...},
                    "sender": {"key_id": "...", "ed25519_public_key": "..."}}
                   {"type": "sent", "delivered": n, "offline": n, "not_allowed": n}
                   {"type": "pong"} | {"type": "error", "detail": "..."}
The token goes in the first message, not the URL, so it never lands in access logs. It is
re-checked on every message; when it expires the socket closes with 4401 and the app reconnects
with a fresh token. Contacts receive only during the traveller's open journey or alert (rule 4).
"""

import asyncio
import logging
import time
from collections import deque
from typing import Annotated

from fastapi import APIRouter, Depends, WebSocket, WebSocketDisconnect
from starlette.concurrency import run_in_threadpool

from app.core.config import Settings, get_settings
from app.core.db import get_session_factory
from app.core.redis import get_redis
from app.identity.router import CurrentSession, session_from_token
from app.relay.hub import hub
from app.relay.routing import RelayError, route

router = APIRouter(prefix="/relay", tags=["relay"])
log = logging.getLogger(__name__)

AUTH_TIMEOUT_SECONDS = 10
RATE_WINDOW_SECONDS = 5
RATE_MAX_MESSAGES = 10  # a location every ~0.5 s at most
CLOSE_UNAUTHENTICATED = 4401


class _RateLimit:
    def __init__(self) -> None:
        self._times: deque[float] = deque()

    def allow(self) -> bool:
        now = time.monotonic()
        while self._times and now - self._times[0] > RATE_WINDOW_SECONDS:
            self._times.popleft()
        if len(self._times) >= RATE_MAX_MESSAGES:
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
    try:
        await socket.send_json({"type": "ready"})
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
