"""Signed alerts (P2-W6): contacts' phones can prove an alert really came from SixthSense.

Push alerts carry the alert as canonical JSON plus an Ed25519 signature; the app verifies it
with SixthSense's public key (bundled in the app, also at GET /alerts/signing-keys). Telegram
and email can't be verified by a person, so they carry a short code that the SixthSense app
shows on the same alert: a fake message can't know it.
"""

import base64
import hashlib
import hmac
import json
from dataclasses import dataclass
from functools import lru_cache

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

from app.core.config import Settings, get_settings

_DEV_PREFIX = "dev-only-"
_CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"  # no 0/O, 1/I/L


@dataclass(frozen=True)
class SigningKey:
    key_id: str
    private: Ed25519PrivateKey

    def public_b64(self) -> str:
        raw = self.private.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        return base64.b64encode(raw).decode()


def _load(value: str) -> SigningKey:
    if value.startswith(_DEV_PREFIX):
        seed = hashlib.sha256(value.encode()).digest()  # dev only; refused outside dev
    else:
        seed = base64.b64decode(value, validate=True)
        if len(seed) != 32:
            raise ValueError("ALERT_SIGNING_KEY must be a base64 32-byte Ed25519 seed")
    private = Ed25519PrivateKey.from_private_bytes(seed)
    raw = private.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    return SigningKey(hashlib.sha256(raw).hexdigest()[:16], private)


@lru_cache
def signing_keys(current: str, previous: str) -> tuple[SigningKey, ...]:
    keys = [_load(current)]
    if previous:
        keys.append(_load(previous))
    return tuple(keys)


def current_key(settings: Settings | None = None) -> SigningKey:
    settings = settings or get_settings()
    return signing_keys(settings.alert_signing_key, settings.alert_signing_key_previous)[0]


def canonical(payload: dict) -> bytes:
    """The exact bytes that are signed: sorted keys, no spaces, UTF-8."""
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def sign(payload: dict, settings: Settings | None = None) -> dict[str, str]:
    """Push `data` fields: the alert JSON, its signature and the signing key id."""
    key = current_key(settings)
    body = canonical(payload)
    return {
        "alert": body.decode(),
        "sig": base64.b64encode(key.private.sign(body)).decode(),
        "kid": key.key_id,
    }


def verification_code(secret: str, escalation_id: str, contact_id: str) -> str:
    """Short code shown in Telegram/email and on the same alert in the app, e.g. 7KQ2-9M4D."""
    digest = hmac.new(
        secret.encode(), f"alert-code|{escalation_id}|{contact_id}".encode(), hashlib.sha256
    ).digest()
    chars = [_CODE_ALPHABET[b % len(_CODE_ALPHABET)] for b in digest[:8]]
    return f"{''.join(chars[:4])}-{''.join(chars[4:])}"
