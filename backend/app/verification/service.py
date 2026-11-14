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
from app.verification.face_match import (
    FaceComparison,
    FaceMatchError,
    best_embedding_match,
    compare_faces,
    compare_template_to_selfie,
)
from app.verification.models import FaceTemplate, IdentityRecord, VerificationSession
from app.verification.providers import MockProvider, ProviderResult
from app.verification.template_crypto import decrypt_embedding, encrypt_embedding

ID_TYPES = {"drivers_license", "voter_id", "passport"}
CONSENT_VERSION = "verification-v1"


def _hmac(secret: str, purpose: str, value: str) -> bytes:
    return hmac.new(secret.encode(), f"{purpose}:{value}".encode(), hashlib.sha256).digest()


def normalized_id(value: str) -> str:
    return "".join(value.upper().split()).replace("-", "")


def start_session(
    db: Session, account_id: uuid.UUID, now: datetime, face_template_consent: bool = False
) -> VerificationSession:
    session = VerificationSession(
        account_id=account_id,
        purpose="responder",
        provider="mock",
        status="pending",
        attempt_no=1,
        consent_version=CONSENT_VERSION,
        consent_at=now,
        face_template_consent=face_template_consent,
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

    from app.moderation import service as moderation  # lazy: moderation imports this package

    banned = moderation.banned_faces(db)
    template_unavailable = False
    try:
        comparison = compare_faces(
            settings,
            id_image=id_image,
            id_image_type=id_image_type,
            selfie_image=selfie_image,
            selfie_image_type=selfie_image_type,
            # Embeddings are needed to keep a template (consented) or to check the ban list.
            capture_template=session.face_template_consent or bool(banned),
        )
    except FaceMatchError as exc:
        if banned:
            # The ban list must be checked: fail closed rather than skip it.
            status_code = 422 if exc.code == "face_image_invalid" else 503
            raise HTTPException(status_code, exc.code) from exc
        if session.face_template_consent and exc.code in {
            "face_template_unavailable",
            "face matcher request failed",
        }:
            # Template storage is optional and must not block the underlying identity check.
            try:
                comparison = compare_faces(
                    settings,
                    id_image=id_image,
                    id_image_type=id_image_type,
                    selfie_image=selfie_image,
                    selfie_image_type=selfie_image_type,
                )
                template_unavailable = True
            except FaceMatchError as fallback_exc:
                status_code = 422 if fallback_exc.code == "face_image_invalid" else 503
                raise HTTPException(status_code, fallback_exc.code) from fallback_exc
        else:
            status_code = 422 if exc.code == "face_image_invalid" else 503
            raise HTTPException(status_code, exc.code) from exc
    similarity = comparison.similarity if isinstance(comparison, FaceComparison) else comparison
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
    if moderation.banned_hashes(db, id_hash, person_hash) or _banned_face(
        settings, comparison, banned
    ):
        session.status = "rejected"
        session.reason_code = "not_eligible"
        session.completed_at = now
        audit.record(db, "verification.banned_match", actor=session.account_id)
        return ProviderResult("rejected", "not_eligible")
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
    if session.face_template_consent and isinstance(comparison, FaceComparison):
        if comparison.source_embedding is None or comparison.calculator_version is None:
            raise HTTPException(503, "face_template_unavailable")
        template = db.get(FaceTemplate, session.account_id)
        values = {
            "embedding_enc": encrypt_embedding(settings, comparison.source_embedding),
            "calculator_version": comparison.calculator_version,
            "consent_version": "walk-face-template-v1",
            "consent_at": session.consent_at,
            "last_used_at": None,
        }
        if template is None:
            db.add(FaceTemplate(account_id=session.account_id, **values))
        else:
            for field, value in values.items():
                setattr(template, field, value)
        audit.record(db, "verification.face_template_enrolled", actor=session.account_id)
    elif session.face_template_consent and template_unavailable:
        audit.record(
            db, "verification.face_template_enrollment_unavailable", actor=session.account_id
        )
    session.status = "verified"
    session.completed_at = now
    audit.record(db, "verification.verified", actor=session.account_id)
    return result


def _banned_face(
    settings: Settings, comparison: float | FaceComparison, banned: list[tuple[bytes, str]]
) -> bool:
    """Does the live selfie match anyone on the ban list? Embeddings are compared in memory."""
    if not banned:
        return False
    selfie = comparison.target_embedding if isinstance(comparison, FaceComparison) else None
    if selfie is None:
        raise HTTPException(503, "face_match_unavailable")
    targets = [
        decrypt_embedding(settings, enc)
        for enc, version in banned
        if version == comparison.calculator_version
    ]
    try:
        best = best_embedding_match(settings, selfie, targets)
    except FaceMatchError as exc:
        raise HTTPException(503, exc.code) from exc
    return best >= settings.compreface_match_threshold


def check_walk_selfie(
    db: Session,
    account_id: uuid.UUID,
    settings: Settings,
    selfie_image: bytes,
    selfie_image_type: str,
    now: datetime,
) -> bool:
    template = db.get(FaceTemplate, account_id)
    if template is None:
        raise HTTPException(409, "face_template_not_enrolled")
    try:
        embedding = decrypt_embedding(settings, template.embedding_enc)
        score = compare_template_to_selfie(
            settings,
            template_embedding=embedding,
            calculator_version=template.calculator_version,
            selfie_image=selfie_image,
            selfie_image_type=selfie_image_type,
        )
    except FaceMatchError as exc:
        status_code = 422 if exc.code == "face_image_invalid" else 503
        raise HTTPException(status_code, exc.code) from exc
    template.last_used_at = now
    matched = score >= settings.compreface_match_threshold
    audit.record(
        db, "walk.face_check_passed" if matched else "walk.face_check_failed", actor=account_id
    )
    return matched


def enroll_face_template(
    db: Session,
    account_id: uuid.UUID,
    settings: Settings,
    id_image: bytes,
    id_image_type: str,
    selfie_image: bytes,
    selfie_image_type: str,
    now: datetime,
) -> bool:
    try:
        comparison = compare_faces(
            settings,
            id_image=id_image,
            id_image_type=id_image_type,
            selfie_image=selfie_image,
            selfie_image_type=selfie_image_type,
            capture_template=True,
        )
    except FaceMatchError as exc:
        status_code = 422 if exc.code == "face_image_invalid" else 503
        raise HTTPException(status_code, exc.code) from exc
    if not isinstance(comparison, FaceComparison):
        raise HTTPException(503, "face_template_unavailable")
    if comparison.similarity < settings.compreface_match_threshold:
        audit.record(db, "verification.face_template_enrollment_failed", actor=account_id)
        return False
    if comparison.source_embedding is None or comparison.calculator_version is None:
        raise HTTPException(503, "face_template_unavailable")
    template = db.get(FaceTemplate, account_id)
    values = {
        "embedding_enc": encrypt_embedding(settings, comparison.source_embedding),
        "calculator_version": comparison.calculator_version,
        "consent_version": "walk-face-template-v1",
        "consent_at": now,
        "last_used_at": None,
    }
    if template is None:
        db.add(FaceTemplate(account_id=account_id, **values))
    else:
        for field, value in values.items():
            setattr(template, field, value)
    audit.record(db, "verification.face_template_consent_granted", actor=account_id)
    audit.record(db, "verification.face_template_enrolled", actor=account_id)
    return True
