import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class ProtocolSettings(BaseModel):
    """Journey settings in minutes. The phone runs the same timers locally (ADR-2)."""

    check_in_interval_min: int = Field(15, ge=1, le=240)
    check_in_grace_min: int = Field(2, ge=0, le=30, description="T1: due → private prompt")
    prompt_timeout_min: int = Field(2, ge=1, le=30, description="T2: private prompt → contacts")
    contact_response_min: int = Field(5, ge=1, le=60, description="Contacts → full escalation")
    heartbeat_timeout_min: int = Field(10, ge=2, le=120, description="Silent phone → contacts")
    auto_112: bool = False
    alert_contact_ids: list[uuid.UUID] | None = Field(
        None, max_length=5, description="trusted contact link ids; null = all accepted contacts"
    )


class JourneyStart(BaseModel):
    check_in_interval_min: int | None = Field(
        None, ge=1, le=240, description="Override the protocol interval for this journey"
    )


class CheckIn(BaseModel):
    result: Literal["ok", "duress"] = Field(
        description="Which PIN the phone accepted. The PIN itself never leaves the phone."
    )


class Sos(BaseModel):
    covert: bool = False


class JourneyView(BaseModel):
    """What the owner's phone sees. A covert escalation is shown as a normal journey."""

    id: uuid.UUID
    state: Literal[
        "active", "check_in_due", "private_prompt", "contact_alert", "full_escalation", "resolved"
    ]
    outcome: Literal["arrived", "ended", "resolved_by_contact"] | None
    started_at: datetime
    next_check_in_at: datetime
    timers: ProtocolSettings
