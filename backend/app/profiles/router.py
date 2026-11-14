"""My profile (P1-W3-profile-tab). Only the owner reads or writes it here."""

from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status

from app.core import audit
from app.identity.router import CurrentSessionDep, DbDep
from app.profiles import schemas
from app.profiles.models import Profile

router = APIRouter(prefix="/profile", tags=["profile"])


def _now() -> datetime:
    return datetime.now(UTC)


NowDep = Annotated[datetime, Depends(_now)]


def _out(profile: Profile) -> schemas.ProfileOut:
    return schemas.ProfileOut(
        first_name=profile.first_name,
        bio=profile.bio,
        strengths=list(profile.strengths),
        languages=list(profile.languages),
        gender=profile.gender,
        willing_companion=profile.willing_companion,
    )


@router.get("", response_model=schemas.ProfileOut)
def get_profile(session: CurrentSessionDep, db: DbDep) -> schemas.ProfileOut:
    """404 `no_profile` right after the first sign-in: the app then asks for it."""
    profile = db.get(Profile, session.account_id)
    if profile is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no_profile")
    return _out(profile)


@router.put("", response_model=schemas.ProfileOut)
def put_profile(
    body: schemas.ProfileIn, session: CurrentSessionDep, db: DbDep, now: NowDep
) -> schemas.ProfileOut:
    profile = db.get(Profile, session.account_id)
    if profile is None:
        profile = Profile(account_id=session.account_id)
        db.add(profile)
    profile.first_name = body.first_name
    profile.bio = body.bio
    profile.strengths = list(dict.fromkeys(body.strengths))
    profile.languages = list(dict.fromkeys(body.languages))
    profile.gender = body.gender
    profile.willing_companion = body.willing_companion
    profile.updated_at = now
    audit.record(db, "profile.updated", actor=session.account_id)
    db.commit()
    return _out(profile)


def first_name_of(db, account_id) -> str | None:
    profile = db.get(Profile, account_id)
    return profile.first_name if profile else None
