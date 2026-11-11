"""walks module (owner: P3).

Walk With Me lifecycle, handshake code, public meeting/drop points, close + wipe, identity
escrow. Per-walk pseudonyms; companion never sees destination; escrow shredded after 30 days.
"""

from app.walks.router import router

__all__ = ["router"]
