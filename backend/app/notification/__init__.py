"""notification module (owner: P2).

Push -> SMS -> voice delivery with retries, delivery receipts, signed short codes.
"""

from app.notification.router import router

__all__ = ["router"]
