"""walks module (owner: P3): Walk With Me.

Companions pass a (demo) verification and are approved by hand (scripts/companions.py); then
they may go "available" with a rough area (~110 m, Redis, minutes). A traveller on an open
journey sees available companions nearby (first name, bio, strengths, rating, rough distance)
and asks one; the companion sees only the traveller's first name and rough area, and accepts or
declines within 10 minutes. On accept both see the same 4-digit handshake code and share live
location with each other over the end-to-end encrypted relay (session id = walk id). Journey
check-ins and SOS keep running; an SOS during a walk also alerts the companion.
"""

from app.walks.router import router

__all__ = ["router"]
