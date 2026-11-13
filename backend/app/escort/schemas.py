import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class EscortStart(BaseModel):
    journey_id: uuid.UUID
    minutes: int = Field(ge=5, le=180, description="How long it runs; 3 hours at most")
    contact_link_ids: list[uuid.UUID] = Field(min_length=1, max_length=5)
    request_id: uuid.UUID | None = Field(None, description="The request this answers, if any")


class EscortStop(BaseModel):
    result: Literal["ok", "duress"] = Field(
        description="Which PIN the phone accepted. Both get the same response; duress also "
        "starts a covert SOS. The PIN itself never leaves the phone."
    )


class EscortView(BaseModel):
    id: uuid.UUID
    journey_id: uuid.UUID
    started_at: datetime
    ends_at: datetime
    listener_link_ids: list[uuid.UUID]


class Stopped(BaseModel):
    stopped: bool = True


class Listening(BaseModel):
    """An escort I may listen to. `owner_label` is the name the owner shows me."""

    escort_id: uuid.UUID
    journey_id: uuid.UUID
    contact_link_id: uuid.UUID
    owner_label: str
    ends_at: datetime


class ListeningList(BaseModel):
    escorts: list[Listening]


class RequestCreate(BaseModel):
    contact_link_id: uuid.UUID


class RequestView(BaseModel):
    id: uuid.UUID
    contact_link_id: uuid.UUID
    created_at: datetime


class RequestList(BaseModel):
    requests: list[RequestView]


class Supported(BaseModel):
    """Someone who added me as a trusted contact (the name is the one they chose to show me)."""

    contact_link_id: uuid.UUID
    owner_label: str


class SupportedList(BaseModel):
    people: list[Supported]
