"""journey module (owner: P2).

Journey state machine, check-ins, PIN/duress handling, heartbeat watchdog. Duress PIN returns
the same response as the real PIN; 3 wrong PINs = coercion.
"""

from app.journey.router import router

__all__ = ["router"]
