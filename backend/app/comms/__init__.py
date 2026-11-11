"""comms module (owner: P3).

Masked chat/voice during walks. No phone numbers exchanged; channel expires 30 min after close.
"""

from app.comms.router import router

__all__ = ["router"]
