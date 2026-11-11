"""relay module (owner: P2).

Forwards E2E-encrypted location between traveller and contacts/companion. Ciphertext only; NEVER
persisted.
"""

from app.relay.router import router

__all__ = ["router"]
