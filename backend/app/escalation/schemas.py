import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class ActiveEscalation(BaseModel):
    """An alert a contact is part of. Visible only while it is open (rule 4)."""

    id: uuid.UUID
    journey_id: uuid.UUID | None = Field(
        default=None, description="Matches session_id in live location envelopes"
    )
    owner_label: str
    level: Literal["contact_alert", "full_escalation"]
    covert: bool = Field(description="Silent alarm: do not call their phone")
    opened_at: datetime
    acknowledged: bool
    i_am_helping: bool = Field(default=False, description="This contact said they are going")
    helpers_going: int = Field(default=0, description="People who said they are going")
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


class HelperKey(BaseModel):
    key_id: uuid.UUID
    x25519_public_key: str
    ed25519_public_key: str


class Helper(BaseModel):
    """Someone coming to help, as the traveller sees them."""

    id: uuid.UUID
    kind: Literal["contact", "responder"]
    label: str | None = Field(
        description="Responder's display name; contacts are named on the phone"
    )
    contact_link_id: uuid.UUID | None = Field(
        description="For contacts: the link id the phone knows"
    )
    status: Literal["going", "arrived"]
    accepted_at: datetime
    keys: list[HelperKey] = Field(description="Encrypt live location to these; verify theirs")


class ResponderSearch(BaseModel):
    """Counts only: the traveller never learns who is on duty or where (rule 4)."""

    radius_m: int = Field(description="Current search radius: 500, then 1000, then 2000")
    on_duty_nearby: int = Field(description="Approved responders on duty within the radius")
    asked: int
    going: int


class HelpView(BaseModel):
    """What the traveller's phone polls during a journey."""

    full_alert: bool = Field(description="A full alert is open: send the rough area for responders")
    any_alert: bool
    helpers: list[Helper]
    search: ResponderSearch | None = Field(
        default=None, description="Nearby responder search, during a full alert"
    )


class AlertArea(BaseModel):
    """Rough area during a full alert, for finding responders. Rounded to ~110 m on the server
    and kept in Redis for 10 minutes; precise location only ever goes end to end encrypted."""

    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)


class OwnerKeys(BaseModel):
    """The traveller's device keys, for a helper to share their own location back."""

    journey_id: uuid.UUID
    keys: list[HelperKey]
