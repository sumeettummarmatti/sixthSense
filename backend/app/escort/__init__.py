"""escort module (owner: P2): Audio Escort sessions (P1-W3-audio-escort).

The owner chooses who listens, for how long (≤ 3 h), and ends it with their PIN. The audio itself
goes end-to-end encrypted through the relay; this module only stores who may listen and until
when. No audio, location or route is ever stored here.
"""

from app.escort.router import router

__all__ = ["router"]
