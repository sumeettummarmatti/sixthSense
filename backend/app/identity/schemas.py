import uuid
from typing import Literal

from pydantic import BaseModel, EmailStr, Field


class OtpRequest(BaseModel):
    email: EmailStr


class OtpRequestAccepted(BaseModel):
    status: Literal["sent"] = "sent"


class OtpVerify(BaseModel):
    email: EmailStr
    code: str = Field(pattern=r"^\d{6}$")
    device_public_key: str = Field(
        description="Base64 X.509 SubjectPublicKeyInfo (DER) of an EC P-256 Android Keystore key",
        max_length=512,
    )


class DeviceChallengeRequest(BaseModel):
    device_id: uuid.UUID


class DeviceChallenge(BaseModel):
    nonce: str
    expires_in: int


class DeviceVerify(BaseModel):
    device_id: uuid.UUID
    nonce: str = Field(max_length=128)
    signature: str = Field(
        description="Base64 DER ECDSA signature (SHA256withECDSA) over "
        "'sixthsense-device-auth-v1|<device_id>|<nonce>'",
        max_length=256,
    )


class Session(BaseModel):
    access_token: str
    token_type: Literal["bearer"] = "bearer"  # noqa: S105
    expires_in: int
    account_id: uuid.UUID
    device_id: uuid.UUID


class E2EKeysUpload(BaseModel):
    x25519_public_key: str = Field(
        description="Base64 raw 32-byte X25519 public key", max_length=64
    )
    ed25519_public_key: str = Field(
        description="Base64 raw 32-byte Ed25519 public key", max_length=64
    )


class E2EKeys(BaseModel):
    key_id: uuid.UUID
    x25519_public_key: str
    ed25519_public_key: str
