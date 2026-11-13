"""Hashing, code and token generation, and device-key checks for sign-in.

Nothing here logs or stores a plaintext email, code, token or key.
"""

import base64
import binascii
import hashlib
import hmac
import secrets

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    PublicFormat,
    load_der_public_key,
)

DEVICE_AUTH_CONTEXT = "sixthsense-device-auth-v1"


def normalise_email(email: str) -> str:
    return email.strip().lower()


def email_hmac(pepper: str, email: str) -> bytes:
    """Account lookup key: HMAC-SHA256(pepper, normalised email)."""
    return hmac.new(pepper.encode(), normalise_email(email).encode(), hashlib.sha256).digest()


def keyed_hash(secret: str, purpose: str, value: str) -> str:
    """Hex HMAC used as a Redis key or stored value, so Redis never holds the raw secret."""
    message = f"{purpose}|{value}".encode()
    return hmac.new(secret.encode(), message, hashlib.sha256).hexdigest()


def new_code() -> str:
    return f"{secrets.randbelow(1_000_000):06d}"


def new_token() -> str:
    return secrets.token_urlsafe(32)


class InvalidDeviceKey(ValueError):
    pass


def load_device_key(b64_der: str) -> tuple[ec.EllipticCurvePublicKey, bytes]:
    """Parse a base64 X.509 SubjectPublicKeyInfo (DER) key; only EC P-256 is accepted.

    Returns the key and its canonical DER bytes. This is the format Android's
    `KeyStore` gives from `certificate.publicKey.encoded`.
    """
    try:
        der = base64.b64decode(b64_der, validate=True)
        key = load_der_public_key(der)
    except (binascii.Error, ValueError) as exc:
        raise InvalidDeviceKey("not a DER public key") from exc
    if not isinstance(key, ec.EllipticCurvePublicKey) or not isinstance(key.curve, ec.SECP256R1):
        raise InvalidDeviceKey("device key must be EC P-256")
    canonical = key.public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
    return key, canonical


def key_fingerprint(der: bytes) -> bytes:
    return hashlib.sha256(der).digest()


def device_challenge_message(device_id: str, nonce: str) -> bytes:
    return f"{DEVICE_AUTH_CONTEXT}|{device_id}|{nonce}".encode()


def verify_device_signature(der: bytes, message: bytes, b64_signature: str) -> bool:
    """Check an ECDSA-SHA256 signature in DER form (Android `SHA256withECDSA`)."""
    try:
        signature = base64.b64decode(b64_signature, validate=True)
        key = load_der_public_key(der)
        if not isinstance(key, ec.EllipticCurvePublicKey):
            return False
        key.verify(signature, message, ec.ECDSA(hashes.SHA256()))
    except (binascii.Error, ValueError, InvalidSignature):
        return False
    return True


def load_raw_32_byte_key(b64: str) -> bytes:
    """Decode a base64 raw 32-byte public key (X25519 or Ed25519)."""
    try:
        raw = base64.b64decode(b64, validate=True)
    except binascii.Error as exc:
        raise InvalidDeviceKey("not base64") from exc
    if len(raw) != 32:
        raise InvalidDeviceKey("key must be 32 bytes")
    return raw
