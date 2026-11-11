"""escalation module (owner: P2).

Parallel fan-out to contacts + 112 + responders, ack tracking, channel fallback, signed alerts.
Idempotent per journey; never waits on one channel.
"""

from app.escalation.router import router

__all__ = ["router"]
