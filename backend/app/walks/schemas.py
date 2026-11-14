import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field

from app.escalation.schemas import HelperKey
from app.profiles.schemas import PartnerProfile


class Area(BaseModel):
    """A rough area: rounded to ~110 m on the server."""

    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)


class CompanionMe(BaseModel):
    status: Literal["none", "approved", "revoked"] = Field(
        description="none = not joined; approved = joined (no manual approval); revoked"
    )
    identity_verified: bool = Field(
        False, description="Verified, adult, unexpired identity (ID + selfie)"
    )
    verified_method: str | None = Field(None, description="'identity' = joined after verification")
    verified_at: datetime | None = None
    available: bool = False


class Available(BaseModel):
    available: bool
    expires_in_seconds: int = 0


class Search(BaseModel):
    journey_id: uuid.UUID
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    women_only: bool = False


class CompanionCard(BaseModel):
    companion_id: uuid.UUID
    profile: PartnerProfile
    rating: float | None = Field(None, description="Average companion stars from past walks")
    rating_count: int = 0
    distance_m: int = Field(description="Rounded to 100 m, from rough areas")
    walk_minutes: int


class Companions(BaseModel):
    companions: list[CompanionCard]


class AskIn(BaseModel):
    journey_id: uuid.UUID
    companion_id: uuid.UUID
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)


class WalkRequest(BaseModel):
    """What a companion sees about a request: first name and rough area only."""

    id: uuid.UUID
    traveller_first_name: str
    rough_area: Area | None
    distance_m: int | None
    expires_at: datetime


class WalkRequests(BaseModel):
    requests: list[WalkRequest]


class WalkView(BaseModel):
    id: uuid.UUID = Field(description="Also the live-location session id while accepted")
    role: Literal["traveller", "companion"]
    status: Literal["requested", "accepted", "declined", "expired", "cancelled", "ended"]
    journey_id: uuid.UUID | None = Field(None, description="Traveller only")
    partner: PartnerProfile | None = Field(
        None, description="The other person; for a companion, only after accepting"
    )
    handshake_code: str | None = Field(None, description="Same 4 digits on both phones")
    meet_near: Area | None = Field(None, description="The traveller's rough area")
    partner_keys: list[HelperKey] = Field(default_factory=list)
    expires_at: datetime
    ended_at: datetime | None = None
    end_reason: str | None = None
