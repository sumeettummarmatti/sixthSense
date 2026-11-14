"""Consent-first verification API for responder enrollment."""

import uuid
from datetime import UTC, date, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from pydantic import BaseModel, ConfigDict
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import Settings, get_settings
from app.core.db import get_db
from app.identity.router import CurrentSession, get_current_session
from app.verification.models import FaceTemplate, IdentityRecord, VerificationSession
from app.verification.service import enroll_face_template, start_session, submit_document

router = APIRouter(prefix="/verification", tags=["verification"])
DbDep = Annotated[Session, Depends(get_db)]
SettingsDep = Annotated[Settings, Depends(get_settings)]
SessionDep = Annotated[CurrentSession, Depends(get_current_session)]


class ConsentRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    purpose: str = "responder"
    consent: bool
    face_template_consent: bool = False


MAX_IMAGE_BYTES = 5 * 1024 * 1024


async def _image_bytes(upload: UploadFile) -> bytes:
    if upload.content_type not in {"image/jpeg", "image/png", "image/webp"}:
        raise HTTPException(415, "unsupported_image_type")
    data = await upload.read(MAX_IMAGE_BYTES + 1)
    if not data:
        raise HTTPException(422, "empty_image")
    if len(data) > MAX_IMAGE_BYTES:
        raise HTTPException(413, "image_too_large")
    return data


class VerificationStatus(BaseModel):
    id: uuid.UUID
    status: str
    reason_code: str | None = None
    expires_at: datetime


def _session(db: Session, session_id: uuid.UUID, account_id: uuid.UUID) -> VerificationSession:
    row = db.get(VerificationSession, session_id)
    if row is None or row.account_id != account_id:
        raise HTTPException(404, "verification_session_not_found")
    return row


def _public_status(row: VerificationSession) -> str:
    if row.status == "pending" and row.expires_at <= datetime.now(UTC):
        return "expired"
    # A new consented session is a draft until the user submits both images and ID details.
    if row.status == "pending" and row.completed_at is None:
        return "not_submitted"
    return row.status


def _public_reason(row: VerificationSession, status: str) -> str | None:
    return "session_expired" if status == "expired" and row.reason_code is None else row.reason_code


@router.post("/sessions", response_model=VerificationStatus, status_code=201)
def create_session(body: ConsentRequest, db: DbDep, current: SessionDep) -> VerificationStatus:
    if body.purpose != "responder":
        raise HTTPException(422, "unsupported_verification_purpose")
    if not body.consent:
        raise HTTPException(400, "consent_required")
    row = start_session(db, current.account_id, datetime.now(UTC), body.face_template_consent)
    if body.face_template_consent:
        from app.core import audit

        audit.record(db, "verification.face_template_consent_granted", actor=current.account_id)
    db.commit()
    return VerificationStatus(id=row.id, status="not_submitted", expires_at=row.expires_at)


@router.post("/sessions/{session_id}/selfie", response_model=VerificationStatus)
async def submit_selfie(
    session_id: uuid.UUID,
    id_type: Annotated[str, Form()],
    id_number: Annotated[str, Form(min_length=1, max_length=100)],
    date_of_birth: Annotated[date, Form()],
    id_image: Annotated[UploadFile, File()],
    selfie_image: Annotated[UploadFile, File()],
    db: DbDep,
    current: SessionDep,
    settings: SettingsDep,
    scenario: Annotated[str | None, Form()] = None,
) -> VerificationStatus:
    row = _session(db, session_id, current.account_id)
    id_bytes = await _image_bytes(id_image)
    selfie_bytes = await _image_bytes(selfie_image)
    submit_document(
        db,
        row,
        settings,
        id_type,
        id_number,
        date_of_birth,
        scenario,
        id_bytes,
        id_image.content_type or "image/jpeg",
        selfie_bytes,
        selfie_image.content_type or "image/jpeg",
        datetime.now(UTC),
    )
    db.commit()
    return VerificationStatus(
        id=row.id, status=row.status, reason_code=row.reason_code, expires_at=row.expires_at
    )


@router.get("/sessions/{session_id}", response_model=VerificationStatus)
def get_session(session_id: uuid.UUID, db: DbDep, current: SessionDep) -> VerificationStatus:
    row = _session(db, session_id, current.account_id)
    status = _public_status(row)
    return VerificationStatus(
        id=row.id,
        status=status,
        reason_code=_public_reason(row, status),
        expires_at=row.expires_at,
    )


@router.get("/me")
def get_me(db: DbDep, current: SessionDep) -> dict:
    identity = db.get(IdentityRecord, current.account_id)
    latest = db.scalar(
        select(VerificationSession)
        .where(VerificationSession.account_id == current.account_id)
        .order_by(VerificationSession.created_at.desc())
    )
    status = _public_status(latest) if latest else "not_started"
    return {
        "status": "verified" if identity and not identity.revoked_at else status,
        "is_adult": identity.is_adult if identity else None,
        "valid_until": identity.valid_until if identity else None,
        "session_id": latest.id if latest else None,
        "reason_code": _public_reason(latest, status) if latest else None,
        "face_template_enabled": db.get(FaceTemplate, current.account_id) is not None,
    }


@router.delete("/face-template", status_code=204)
def delete_face_template(db: DbDep, current: SessionDep) -> None:
    from app.core import audit

    template = db.get(FaceTemplate, current.account_id)
    if template is not None:
        db.delete(template)
        audit.record(db, "verification.face_template_deleted", actor=current.account_id)
        db.commit()


@router.post("/face-template")
async def enroll_reusable_face_template(
    consent: Annotated[bool, Form()],
    id_image: Annotated[UploadFile, File()],
    selfie_image: Annotated[UploadFile, File()],
    db: DbDep,
    current: SessionDep,
    settings: SettingsDep,
) -> dict[str, bool]:
    identity = db.get(IdentityRecord, current.account_id)
    now = datetime.now(UTC)
    if (
        identity is None
        or not identity.is_adult
        or identity.revoked_at is not None
        or identity.valid_until <= now
    ):
        raise HTTPException(403, "identity_not_verified")
    if not consent:
        raise HTTPException(400, "face_template_consent_required")
    id_bytes = await _image_bytes(id_image)
    selfie_bytes = await _image_bytes(selfie_image)
    matched = enroll_face_template(
        db,
        current.account_id,
        settings,
        id_bytes,
        id_image.content_type or "image/jpeg",
        selfie_bytes,
        selfie_image.content_type or "image/jpeg",
        now,
    )
    db.commit()
    if not matched:
        raise HTTPException(422, "face_mismatch")
    return {"enabled": True}
