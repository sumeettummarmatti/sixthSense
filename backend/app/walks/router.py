from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from pydantic import BaseModel
from sqlalchemy.orm import Session

from app.core.config import Settings, get_settings
from app.core.db import get_db
from app.identity.router import CurrentSession, get_current_session
from app.verification.eligibility import eligible
from app.verification.service import check_walk_selfie

router = APIRouter(prefix="/walks", tags=["walks"])
DbDep = Annotated[Session, Depends(get_db)]
SettingsDep = Annotated[Settings, Depends(get_settings)]
SessionDep = Annotated[CurrentSession, Depends(get_current_session)]
MAX_SELFIE_BYTES = 5 * 1024 * 1024


class FaceCheckResponse(BaseModel):
    matched: bool


@router.post("/face-check", response_model=FaceCheckResponse)
async def walk_face_check(
    selfie_image: Annotated[UploadFile, File()],
    db: DbDep,
    current: SessionDep,
    settings: SettingsDep,
) -> FaceCheckResponse:
    """Require an approved, verified companion and fresh match before each walk request."""
    now = datetime.now(UTC)
    if not eligible(db, current.account_id, "companion", now):
        raise HTTPException(403, "not_eligible")
    if selfie_image.content_type not in {"image/jpeg", "image/png", "image/webp"}:
        raise HTTPException(415, "unsupported_image_type")
    image = await selfie_image.read(MAX_SELFIE_BYTES + 1)
    if not image:
        raise HTTPException(422, "empty_image")
    if len(image) > MAX_SELFIE_BYTES:
        raise HTTPException(413, "image_too_large")
    matched = check_walk_selfie(
        db,
        current.account_id,
        settings,
        image,
        selfie_image.content_type,
        now,
    )
    db.commit()
    return FaceCheckResponse(matched=matched)
