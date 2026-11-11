"""risk module (owner: P4).

Risk layer for routing and the dashboard. Labels come from app.risk.labels; never 'safe'.
"""

from app.risk.router import router

__all__ = ["router"]
