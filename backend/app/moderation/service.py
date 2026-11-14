"""Suspend, ban and restore helpers; keep banned people from verifying again (P2-W4-helper-ban).

- A 1-star rating of a companion or responder suspends them from helping at once and opens a
  case. Admins see the case and the rating, never the person's name or account (rule 4).
- Ban (admin): the account is blocked from the whole app (status 'suspended', devices revoked,
  live tokens refused), helper roles and the verified identity are revoked, and the keyed ID
  hashes plus the encrypted face embedding are copied to banned_identities.
- A new verification is refused when its ID hashes or the selfie's face match the ban list.
- Restore (admin): the suspension was unfair; the helper can help again.

Every step is audited by case id, without personal data (rule 7).
"""

import uuid
from datetime import datetime
from typing import Literal

from redis import Redis
from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.core import audit
from app.identity.models import Account, Device
from app.identity.router import BANNED_ACCOUNTS_KEY
from app.matching.models import ResponderProfile
from app.moderation.models import BannedIdentity, ModerationCase
from app.verification.models import FaceTemplate, IdentityRecord
from app.verification.revocation import revoke_responder
from app.walks.models import CompanionProfile

Role = Literal["companion", "responder"]
SUSPEND_AT_STARS = 1
BANNED_KEY = BANNED_ACCOUNTS_KEY  # Redis set of account ids whose live tokens are refused


def is_banned(redis: Redis, account_id: uuid.UUID) -> bool:
    return bool(redis.sismember(BANNED_KEY, str(account_id)))


def _revoke_role(
    db: Session, redis: Redis, account_id: uuid.UUID, role: Role, now: datetime, reason: str
) -> None:
    if role == "responder":
        revoke_responder(db, redis, account_id, now, reason)
    else:
        from app.walks.service import revoke_companion  # lazy: walks -> feedback -> here

        revoke_companion(db, redis, account_id, now)


def open_case(
    db: Session,
    account_id: uuid.UUID,
    role: Role,
    source: str,
    stars: int | None,
    now: datetime,
) -> ModerationCase:
    case = ModerationCase(
        account_id=account_id,
        role=role,
        source=source,
        stars=stars,
        status="suspended",
        opened_at=now,
    )
    db.add(case)
    db.flush()
    return case


def rated(
    db: Session,
    redis: Redis,
    account_id: uuid.UUID,
    role: Role,
    source: str,
    stars: int,
    now: datetime,
) -> ModerationCase | None:
    """Called for every helper rating. A 1-star rating suspends the helper now."""
    if stars > SUSPEND_AT_STARS:
        return None
    case = open_case(db, account_id, role, source, stars, now)
    _revoke_role(db, redis, account_id, role, now, "suspended_bad_rating")
    audit.record(db, f"moderation.suspended.{role}", target=f"case:{case.id}")
    return case


def ban(db: Session, redis: Redis, case: ModerationCase, now: datetime) -> None:
    """Block the account from the app and remember its ID hashes and face for re-verification."""
    account_id = case.account_id
    for role in ("companion", "responder"):
        _revoke_role(db, redis, account_id, role, now, "banned")
    identity = db.get(IdentityRecord, account_id)
    template = db.get(FaceTemplate, account_id)
    db.add(
        BannedIdentity(
            case_id=case.id,
            id_hmac=identity.id_hmac if identity else None,
            person_hmac=identity.person_hmac if identity else None,
            embedding_enc=template.embedding_enc if template else None,
            calculator_version=template.calculator_version if template else None,
            banned_at=now,
        )
    )
    if identity is not None and identity.revoked_at is None:
        identity.revoked_at, identity.revoked_reason = now, "banned"
    account = db.get(Account, account_id)
    if account is not None:
        account.status = "suspended"  # sign-in answers 403 account_suspended
    db.execute(
        update(Device)
        .where(Device.account_id == account_id, Device.revoked_at.is_(None))
        .values(revoked_at=now)
    )
    case.status, case.decided_at = "banned", now
    redis.sadd(BANNED_KEY, str(account_id))
    audit.record(
        db,
        "moderation.banned",
        target=f"case:{case.id}",
    )


def restore(db: Session, case: ModerationCase, now: datetime) -> None:
    """The rating was unfair: the helper can help again."""
    if case.role == "responder":
        profile = db.get(ResponderProfile, (case.account_id, "responder"))
    else:
        profile = db.get(CompanionProfile, case.account_id)
    if profile is not None and profile.status == "revoked":
        profile.status, profile.approved_at = "approved", now
    case.status, case.decided_at = "restored", now
    audit.record(db, "moderation.restored", target=f"case:{case.id}")


def case_for_source(db: Session, source: str) -> ModerationCase | None:
    return db.scalars(
        select(ModerationCase)
        .where(ModerationCase.source == source)
        .order_by(ModerationCase.opened_at.desc())
    ).first()


def banned_hashes(db: Session, id_hmac: bytes, person_hmac: bytes) -> bool:
    return (
        db.scalar(
            select(BannedIdentity.id).where(
                (BannedIdentity.id_hmac == id_hmac) | (BannedIdentity.person_hmac == person_hmac)
            )
        )
        is not None
    )


def banned_faces(db: Session) -> list[tuple[bytes, str]]:
    """(encrypted embedding, calculator version) for every banned person with a face on file."""
    return [
        (row.embedding_enc, row.calculator_version)
        for row in db.scalars(
            select(BannedIdentity).where(BannedIdentity.embedding_enc.is_not(None))
        )
        if row.calculator_version
    ]
