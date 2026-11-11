"""identity module (owner: P2/P3).

OTP, device-bound keys, trust tiers, verification orchestration. Store only the verification
OUTCOME; dedupe via HMAC(pepper, name|DOB|gender); never an Aadhaar number or ID image.
"""

from app.identity.router import router

__all__ = ["router"]
