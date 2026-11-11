"""Open relay connections, by device. In memory only: nothing is queued or stored (ADR-3).

One API process holds all connections, which fits the single-server pilot. Running several
API processes needs this swapped for Redis pub/sub (also not persisted).
"""

import asyncio
import uuid
from collections import defaultdict

from fastapi import WebSocket


class Hub:
    def __init__(self) -> None:
        self._sockets: dict[uuid.UUID, set[WebSocket]] = defaultdict(set)
        self._lock = asyncio.Lock()

    async def add(self, device_id: uuid.UUID, socket: WebSocket) -> None:
        async with self._lock:
            self._sockets[device_id].add(socket)

    async def remove(self, device_id: uuid.UUID, socket: WebSocket) -> None:
        async with self._lock:
            self._sockets[device_id].discard(socket)
            if not self._sockets[device_id]:
                del self._sockets[device_id]

    async def deliver(self, device_id: uuid.UUID, frame: dict) -> bool:
        """Send to every open connection of a device. False if it isn't connected (dropped)."""
        sockets = list(self._sockets.get(device_id, ()))
        delivered = False
        for socket in sockets:
            try:
                await socket.send_json(frame)
                delivered = True
            except (RuntimeError, OSError):
                await self.remove(device_id, socket)
        return delivered


hub = Hub()
