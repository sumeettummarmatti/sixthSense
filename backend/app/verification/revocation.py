"""Revoke responder access and clean up all active offers/helpers (P3-W2)."""

import re
import uuid
from datetime import datetime

from redis import Redis
from sqlalchemy import delete, select, update
from sqlalchemy.orm import Session

from app.core import audit
from app.escalation.models import Escalation, EscalationHelper
from app.matching import nearby
from app.matching.models import ResponderOffer, ResponderProfile

_REASON_CODE = re.compile(r"^[a-z0-9_]{1,40}$")


def revoke_responder(
    db: Session,
    redis: Redis,
    account_id: uuid.UUID,
    now: datetime,
    reason_code: str = "admin_action",
) -> bool:
    """Revoke the responder role. Commit the SQL changes in the caller's transaction.

    Redis presence is removed first (fail closed); SQL status, offers, helper rows, and audit
    event are written together and committed by the caller.
    """
    reason_code = reason_code.strip().lower()
    if not _REASON_CODE.fullmatch(reason_code):
        raise ValueError("reason_code must be a short lowercase code")

    profile = db.get(ResponderProfile, (account_id, "responder"))
    if profile is None:
        return False

    nearby.clear_presence(redis, account_id)
    profile.status = "revoked"
    open_escalations = select(Escalation.id).where(Escalation.closed_at.is_(None))
    db.execute(
        update(ResponderOffer)
        .where(
            ResponderOffer.responder_id == account_id,
            ResponderOffer.escalation_id.in_(open_escalations),
            ResponderOffer.status != "declined",
        )
        .values(status="declined", responded_at=now)
    )
    db.execute(
        delete(EscalationHelper).where(
            EscalationHelper.account_id == account_id,
            EscalationHelper.escalation_id.in_(open_escalations),
        )
    )
    audit.record(
        db,
        f"responder.revoked.{reason_code}",
        target=f"account:{account_id}",
    )
    return True
