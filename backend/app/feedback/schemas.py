import uuid
from typing import Annotated, Literal

from pydantic import BaseModel, Field, StringConstraints, model_validator

Chip = Literal[
    "well_lit",
    "felt_uneasy",
    "companion_was_late",
    "route_confusing",
    "would_walk_again",
    "busy_street",
    "poor_footpath",
]
Note = Annotated[str, StringConstraints(strip_whitespace=True, max_length=500)]


class FeedbackIn(BaseModel):
    journey_id: uuid.UUID
    walk_id: uuid.UUID | None = None
    route_stars: int = Field(ge=1, le=5)
    companion_stars: int | None = Field(None, ge=1, le=5, description="Only with a walk_id")
    chips: list[Chip] = Field(default_factory=list, max_length=7)
    note: Note = ""

    @model_validator(mode="after")
    def _companion_needs_walk(self) -> "FeedbackIn":
        if self.companion_stars is not None and self.walk_id is None:
            raise ValueError("companion_stars needs walk_id")
        return self


class FeedbackOut(BaseModel):
    id: uuid.UUID
