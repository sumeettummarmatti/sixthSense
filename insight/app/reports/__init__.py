"""reports module (owner: P4).

Accept anonymous place/condition reports. No user ID (attestation token only);
reject person-identifying text (names, phones, plates); per-device rate limit.
"""

from app.reports.router import router

__all__ = ["router"]
