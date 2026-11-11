"""matching module (owner: P3).

Find eligible companions nearby. Coarse cell only; per-hour alert caps; no re-matching the same
pair within 14 days; women-only / campus-only filters.
"""

from app.matching.router import router

__all__ = ["router"]
