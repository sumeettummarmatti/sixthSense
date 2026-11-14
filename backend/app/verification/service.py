"""Verification attempt persistence and duplicate checks."""

import hashlib
import hmac
import uuid
from datetime import date, datetime, timedelta

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core import audit
from app.core.config import Settings
from app.verification.face_match import FaceMatchError, compare_faces
from app.verification.models import IdentityRecord, VerificationSession
from app.verification.providers import MockProvider, ProviderResult

ID_TYPES = {"drivers_license", "voter_id", "passport"}
CONSENT_VERSION = "verification-v1"


def _hmac(secret: str, purpose: str, value: str) -> bytes:
    return hmac.new(secret.encode(), f"{purpose}:{value}".encode(), hashlib.sha256).digest()


def normalized_id(value: str) -> str:
    return "".join(value.upper().split()).replace("-", "")


def start_session(db: Session, account_id: uuid.UUID, now: datetime) -> VerificationSession:
    session = VerificationSession(
        account_id=account_id,
        purpose="responder",
        provider="mock",
        status="pending",
        attempt_no=1,
        consent_version=CONSENT_VERSION,
        consent_at=now,
        expires_at=now + timedelta(minutes=30),
    )
    db.add(session)
    db.flush()
    return session


def submit_document(
    db: Session,
    session: VerificationSession,
    settings: Settings,
    id_type: str,
    id_number: str,
    date_of_birth: date,
    scenario: str | None,
    id_image: bytes,
    id_image_type: str,
    selfie_image: bytes,
    selfie_image_type: str,
    now: datetime,
) -> ProviderResult:
    if session.status != "pending" or session.expires_at <= now:
        raise HTTPException(409, "verification_session_not_pending")
    if id_type not in ID_TYPES:
        raise HTTPException(422, "unsupported_id_type")
    if db.get(IdentityRecord, session.account_id) is not None:
        raise HTTPException(409, "already_verified")

    normalized = normalized_id(id_number)
    if not normalized:
        raise HTTPException(422, "invalid_id_number")
    provider = MockProvider(settings.verification_mock_scenarios, scenario)
    result = provider.verify(id_type, normalized, date_of_birth)
    if result.status != "verified":
        session.status = result.status
        session.reason_code = result.reason_code
        session.completed_at = now
        audit.record(db, f"verification.{result.status}", actor=session.account_id)
        return result

    try:
        similarity = compare_faces(
            settings,
            id_image=id_image,
            id_image_type=id_image_type,
            selfie_image=selfie_image,
            selfie_image_type=selfie_image_type,
        )
    except FaceMatchError as exc:
        status_code = 422 if exc.code == "face_image_invalid" else 503
        raise HTTPException(status_code, exc.code) from exc
    if similarity < settings.compreface_match_threshold:
        session.status = "rejected"
        session.reason_code = "face_mismatch"
        session.completed_at = now
        audit.record(db, "verification.face_mismatch", actor=session.account_id)
        return ProviderResult("rejected", "face_mismatch")

    id_hash = _hmac(settings.identity_hmac_secret, "id", normalized)
    # The mock has no provider-issued cross-document person reference. Use its stable fake
    # document identifier rather than DOB (DOB-only hashes would block unrelated people).
    # A real provider adapter must supply a stable person reference for cross-ID deduplication.
    person_hash = _hmac(settings.identity_hmac_secret, "person", normalized)
    duplicate = db.scalar(select(IdentityRecord).where(IdentityRecord.id_hmac == id_hash))
    if duplicate or db.scalar(
        select(IdentityRecord).where(
            IdentityRecord.person_hmac == person_hash,
            IdentityRecord.revoked_at.is_not(None),
        )
    ):
        session.status = "rejected"
        session.reason_code = "duplicate"
        session.completed_at = now
        audit.record(db, "verification.duplicate", actor=session.account_id)
        return ProviderResult("rejected", "duplicate")

    db.add(
        IdentityRecord(
            account_id=session.account_id,
            id_type=id_type,
            id_hmac=id_hash,
            person_hmac=person_hash,
            hmac_key_version=settings.identity_hmac_key_version,
            is_adult=result.is_adult,
            verified_by="mock",
            verified_at=now,
            valid_until=now + timedelta(days=settings.verification_valid_days),
        )
    )
    session.status = "verified"
    session.completed_at = now
    audit.record(db, "verification.verified", actor=session.account_id)
    return result
