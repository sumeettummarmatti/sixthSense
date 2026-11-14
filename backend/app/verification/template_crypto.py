"""Encryption for reusable biometric face embeddings."""

import base64
import hashlib
import json

from cryptography.fernet import Fernet, InvalidToken

from app.core.config import Settings
from app.verification.face_match import FaceMatchError


def _fernet(settings: Settings) -> Fernet:
    digest = hashlib.sha256(settings.face_template_key.encode()).digest()
    return Fernet(base64.urlsafe_b64encode(digest))


def encrypt_embedding(settings: Settings, embedding: list[float]) -> bytes:
    return _fernet(settings).encrypt(json.dumps(embedding, separators=(",", ":")).encode())


def decrypt_embedding(settings: Settings, ciphertext: bytes) -> list[float]:
    try:
        value = json.loads(_fernet(settings).decrypt(ciphertext))
    except (InvalidToken, ValueError, TypeError) as exc:
        raise FaceMatchError("face_template_unavailable") from exc
    if not isinstance(value, list) or not value or len(value) > 2048:
        raise FaceMatchError("face_template_unavailable")
    if any(not isinstance(component, (int, float)) for component in value):
        raise FaceMatchError("face_template_unavailable")
    return [float(component) for component in value]
