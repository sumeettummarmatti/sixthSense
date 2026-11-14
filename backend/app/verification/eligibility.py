"""Single source of truth for eligibility to act as a responder or companion."""

import uuid
from datetime import datetime, timedelta
from typing import Literal

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core.config import get_settings
from app.identity.models import Device
from app.matching.models import ResponderProfile
from app.verification.models import IdentityRecord

Role = Literal["responder", "companion"]


def eligible(db: Session, account_id: uuid.UUID, role: Role, now: datetime) -> bool:
    """Whether this account may use the requested proximity role at [now].

    Ordinary traveller/contact access deliberately does not call this function.
    """
    identity = db.get(IdentityRecord, account_id)
    if (
        identity is None
        or identity.verified_at is None
        or not identity.is_adult
        or identity.revoked_at is not None
        or identity.valid_until <= now
    ):
        return False

    role_row = db.get(ResponderProfile, (account_id, role))
    if role_row is None or role_row.status != "approved":
        return False

    cooldown_hours = get_settings().key_rotation_cooldown_hours
    if cooldown_hours > 0:
        rotated_at = db.scalar(
            select(func.max(Device.key_rotated_at)).where(
                Device.account_id == account_id,
                Device.revoked_at.is_(None),
                Device.key_rotated_at.is_not(None),
            )
        )
        if rotated_at is not None and rotated_at + timedelta(hours=cooldown_hours) > now:
            return False
    return True
