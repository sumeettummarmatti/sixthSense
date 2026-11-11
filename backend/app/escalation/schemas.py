import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class ActiveEscalation(BaseModel):
    """An alert a contact is part of. Visible only while it is open (rule 4)."""

    id: uuid.UUID
    owner_label: str
    level: Literal["contact_alert", "full_escalation"]
    covert: bool = Field(description="Silent alarm: do not call their phone")
    opened_at: datetime
    acknowledged: bool
    verification_code: str = Field(
        description="Same code as in the Telegram/email alert; if they differ, that message is fake"
    )


class ActiveEscalations(BaseModel):
    escalations: list[ActiveEscalation]


class LinkAck(BaseModel):
    token: str = Field(max_length=128)


class Acknowledged(BaseModel):
    owner_label: str
    acknowledged: bool = True


class Resolved(BaseModel):
    journey_state: Literal["active", "resolved"]


class Raised(BaseModel):
    journey_state: Literal["full_escalation"] = "full_escalation"
