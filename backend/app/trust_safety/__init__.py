"""trust_safety module (owner: P3).

Responder scoring, suspensions, complaints, escrow unseal workflow. 2-officer unseal; immutable
audit log; instant suspension on complaint.
"""

from app.trust_safety.router import router

__all__ = ["router"]
