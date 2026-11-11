"""clustering module (owner: P4).

Group reports by cell x time band x category. Only clusters above the k/m
threshold are ever returned.
"""

from app.clustering.router import router

__all__ = ["router"]
