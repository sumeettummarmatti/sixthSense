"""contacts module (owner: P2).

Trusted contacts: invite link, accept, list, silent remove, E2E key lookup. The server never
stores a contact's phone number or name; the phone keeps those locally for offline SMS.
Contacts see nothing about the owner outside an active journey or alert (rule 4).
"""

from app.contacts.router import router

__all__ = ["router"]
