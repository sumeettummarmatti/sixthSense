from typing import Annotated, Literal

from pydantic import BaseModel, Field, StringConstraints

FirstName = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=40)]
Bio = Annotated[str, StringConstraints(strip_whitespace=True, max_length=200)]
Language = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=30)]
Strength = Literal[
    "knows_the_area",
    "first_aid_trained",
    "walks_this_route_daily",
    "speaks_kannada",
    "speaks_hindi",
    "self_defence_trained",
    "calm_in_a_crisis",
    "campus_volunteer",
]
Gender = Literal["woman", "man", "non_binary"]


class ProfileIn(BaseModel):
    first_name: FirstName
    bio: Bio = ""
    strengths: list[Strength] = Field(default_factory=list, max_length=8)
    languages: list[Language] = Field(default_factory=list, max_length=8)
    gender: Gender | None = Field(None, description="Optional; used only for 'women only' walks")
    willing_companion: bool = False


class ProfileOut(ProfileIn):
    pass


class PartnerProfile(BaseModel):
    """What a walk partner sees: no gender, no account details."""

    first_name: str
    bio: str
    strengths: list[str]
    languages: list[str]
