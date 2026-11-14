"""Fresh face scan at the moment a helper would start receiving someone's location.

Companions scan when they accept a walk; responders scan when they say "I'm going". The scan is
part of that same request, so a modified app cannot skip it and an old selfie cannot be replayed.
This is separate from identity verification (ID + selfie, done once): it checks that the person
holding the phone right now is the one who verified the account.

Providers (FACE_CHECK_PROVIDER):
- mock: the phone has already checked that exactly one face is in front of the front camera;
  the server only checks that a real image was sent. It does NOT match faces. Demo only.
- compreface: the selfie is compared with the encrypted face template saved at verification
  (reuses the verification module's check_walk_selfie). Needs CompreFace and template consent.
- auto: compreface for helpers who saved a face template, the phone check (mock) for the rest,
  so turning real matching on never locks out helpers who verified before templates worked.

The image is read into memory, checked and dropped: it is never stored or logged (rule 2).
"""

import uuid
from datetime import datetime
from typing import Literal

from fastapi import HTTPException, UploadFile, status
from sqlalchemy.orm import Session

from app.core import audit
from app.core.config import Settings
from app.verification.models import FaceTemplate
from app.verification.service import check_walk_selfie

Purpose = Literal["walk", "responder"]
MAX_SCAN_BYTES = 5 * 1024 * 1024
_SIGNATURES = {
    "image/jpeg": lambda data: data[:3] == b"\xff\xd8\xff",
    "image/png": lambda data: data[:8] == b"\x89PNG\r\n\x1a\n",
    "image/webp": lambda data: data[:4] == b"RIFF" and data[8:12] == b"WEBP",
}


def read_scan(upload: UploadFile | None) -> tuple[bytes, str]:
    """The uploaded selfie bytes and type, or a 4xx naming what is wrong."""
    if upload is None:
        raise HTTPException(status.HTTP_428_PRECONDITION_REQUIRED, "face_scan_required")
    content_type = upload.content_type or ""
    if content_type not in _SIGNATURES:
        raise HTTPException(status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, "unsupported_image_type")
    data = upload.file.read(MAX_SCAN_BYTES + 1)
    if not data:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "empty_image")
    if len(data) > MAX_SCAN_BYTES:
        raise HTTPException(status.HTTP_413_CONTENT_TOO_LARGE, "image_too_large")
    if not _SIGNATURES[content_type](data):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "face_image_invalid")
    return data, content_type


def check(
    db: Session,
    settings: Settings,
    account_id: uuid.UUID,
    purpose: Purpose,
    image: bytes,
    content_type: str,
    now: datetime,
    target: str,
) -> None:
    """Pass silently, or raise. A failed match is audited and committed before raising."""
    provider = settings.face_check_provider
    if provider == "auto" and db.get(FaceTemplate, account_id) is None:
        provider = "auto_device"  # no template yet: the phone's one-face check stands
    if provider in ("compreface", "auto"):
        # Raises 409 face_template_not_enrolled / 422 face_image_invalid / 503 when unavailable.
        matched = check_walk_selfie(db, account_id, settings, image, content_type, now)
    else:
        matched = True
    result = "passed" if matched else "failed"
    audit.record(
        db,
        f"{purpose}.face_scan.{result}.{provider}",
        actor=account_id,
        target=target,
    )
    if not matched:
        db.commit()
        raise HTTPException(status.HTTP_403_FORBIDDEN, "face_mismatch")
