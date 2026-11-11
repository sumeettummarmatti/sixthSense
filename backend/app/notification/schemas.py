from pydantic import BaseModel, EmailStr, Field


class ChannelStatus(BaseModel):
    """Which alert channels this account has set up, and which the server can use at all."""

    push: bool = Field(description="This device has sent its FCM token")
    telegram: bool
    email: bool
    push_available: bool
    telegram_available: bool


class PushToken(BaseModel):
    fcm_token: str = Field(min_length=1, max_length=4096)


class TelegramLink(BaseModel):
    url: str
    expires_in: int


class AlertEmail(BaseModel):
    email: EmailStr = Field(description="Must be the email this account signs in with")


class SigningKey(BaseModel):
    key_id: str
    alg: str = "Ed25519"
    ed25519_public_key: str = Field(description="Base64 raw 32-byte public key")


class SigningKeys(BaseModel):
    keys: list[SigningKey] = Field(description="Current key first; a previous key after rotation")
