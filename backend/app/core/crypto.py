"""Encryption for the few identifiers we must keep (FCM tokens, Telegram chat ids, alert emails).

Fernet (AES-128-CBC + HMAC-SHA256) with a key derived from DATA_KEY. Rotating DATA_KEY makes
existing values unreadable, so contacts would need to set their channels up again.
"""

import base64
import hashlib

from cryptography.fernet import Fernet, InvalidToken

from app.core.config import get_settings


def _fernet() -> Fernet:
    digest = hashlib.sha256(get_settings().data_key.encode()).digest()
    return Fernet(base64.urlsafe_b64encode(digest))


def encrypt(value: str) -> bytes:
    return _fernet().encrypt(value.encode())


def decrypt(token: bytes | None) -> str | None:
    if token is None:
        return None
    try:
        return _fernet().decrypt(token).decode()
    except InvalidToken:
        return None
