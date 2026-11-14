"""profiles module (P1-W3-profile-tab).

One profile per account: first name, short bio, strengths, languages, optional gender and
whether the person is willing to be a companion. Shown to someone else only inside a consented
Walk With Me match (or to a traveller choosing among companions who chose to be available);
never browsable, never listed otherwise (rule 4).
"""

from app.profiles.router import router

__all__ = ["router"]
