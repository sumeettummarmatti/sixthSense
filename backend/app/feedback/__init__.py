"""feedback module (P1-W3-journey-feedback, P2-W3-feedback-store-admin).

"How was it?" after a journey or walk: stars, chips and an optional note, stored raw by journey
(and walk) id. No location, no names, no scoring yet. Admins export it by script
(scripts/feedback.py); every write and admin read is in the append-only audit log.
"""

from app.feedback.router import router

__all__ = ["router"]
