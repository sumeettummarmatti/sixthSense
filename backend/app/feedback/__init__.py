"""feedback module (P1-W3-journey-feedback, P2-W3-feedback-store-admin).

"How was it?" after a journey or walk: stars, chips and an optional note, stored raw by journey
(and walk) id. No location, no names, no scoring yet. Admins read it on /admin/feedback
(admin.py, with CSV download) or by script (scripts/feedback.py); every write and admin read is
in the append-only audit log.
"""

from app.feedback.admin import router as admin_router
from app.feedback.router import router

__all__ = ["admin_router", "router"]
