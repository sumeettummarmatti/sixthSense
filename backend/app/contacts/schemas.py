import uuid
from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, Field, StringConstraints

OwnerLabel = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=40)]


class InviteCreate(BaseModel):
    owner_label: OwnerLabel = Field(
        description="How the contact will see you in alerts, e.g. 'Priya'. Not the contact's name."
    )


class Invite(BaseModel):
    contact_link_id: uuid.UUID
    invite_token: str
    invite_url: str
    expires_at: datetime


class InviteAccept(BaseModel):
    invite_token: str = Field(max_length=128)


class InviteAccepted(BaseModel):
    owner_label: str


class ContactLink(BaseModel):
    id: uuid.UUID
    status: Literal["pending", "accepted"]
    created_at: datetime
    accepted_at: datetime | None
    invite_expires_at: datetime | None = Field(description="Only for pending invites")


class ContactList(BaseModel):
    contacts: list[ContactLink]


class ContactKey(BaseModel):
    key_id: uuid.UUID
    x25519_public_key: str
    ed25519_public_key: str


class ContactKeys(BaseModel):
    contact_link_id: uuid.UUID
    keys: list[ContactKey] = Field(description="One entry per active device that uploaded keys")
