import uuid
from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, Field, StringConstraints

from app.escalation.schemas import HelperKey

DisplayName = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=40)]


class Apply(BaseModel):
    display_name: DisplayName = Field(description="How the person in trouble sees you, e.g. 'Riya'")


class Me(BaseModel):
    status: Literal["none", "pending", "approved", "revoked"]
    display_name: str | None = None
    on_duty: bool = False


class Presence(BaseModel):
    """Rough area while on duty; rounded to ~110 m on the server, forgotten after 5 minutes."""

    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)


class OnDuty(BaseModel):
    on_duty: bool
    expires_in_seconds: int = 0


class Area(BaseModel):
    latitude: float
    longitude: float


class Offer(BaseModel):
    id: uuid.UUID
    journey_id: uuid.UUID | None = Field(
        description="Matches session_id of live location, after 'going'"
    )
    status: Literal["offered", "going", "declined"]
    distance_m: int = Field(description="From rough areas, so +-150 m")
    walk_minutes: int
    rough_area: Area | None = Field(description="Rounded to ~110 m; precise only after 'going'")
    covert: bool
    opened_at: datetime
    helpers_going: int
    arrived: bool = False


class Offers(BaseModel):
    offers: list[Offer]


class OwnerKeys(BaseModel):
    journey_id: uuid.UUID
    keys: list[HelperKey]
