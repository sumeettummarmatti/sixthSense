"""Sign-in: email code once per phone, then device-bound keys (P2-W1).

Redis keys (all values and key suffixes are keyed hashes, never raw emails, codes or tokens):
  otp:<email key>          hash {h: code hash, attempts}   TTL otp_ttl_seconds
  rl:otp:email:<email key> request counter                 TTL otp_rate_window_seconds
  rl:otp:ip:<ip hash>      request counter                TTL otp_rate_window_seconds
  dc:<nonce hash>          device id                       TTL device_challenge_ttl_seconds
  at:<token hash>          "<account id>:<device id>"      TTL access_token_ttl_seconds
"""

import base64
import hmac
import logging
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, BackgroundTasks, Depends, Header, HTTPException, Request, status
from redis import Redis
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.core import audit
from app.core.config import Settings, get_settings
from app.core.db import get_db
from app.core.redis import get_redis
from app.identity import schemas, security
from app.identity.mailer import SmtpMailer, get_mailer
from app.identity.models import Account, Device, DeviceE2EKeys

router = APIRouter(prefix="/auth", tags=["identity"])
log = logging.getLogger(__name__)

SettingsDep = Annotated[Settings, Depends(get_settings)]
RedisDep = Annotated[Redis, Depends(get_redis)]
DbDep = Annotated[Session, Depends(get_db)]
MailerDep = Annotated[SmtpMailer, Depends(get_mailer)]

_INVALID_CODE = HTTPException(status.HTTP_400_BAD_REQUEST, "invalid_or_expired_code")
_TOO_MANY_ATTEMPTS = HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "too_many_attempts")
_RATE_LIMITED = HTTPException(
    status.HTTP_429_TOO_MANY_REQUESTS, "rate_limited", headers={"Retry-After": "600"}
)
_DEVICE_AUTH_FAILED = HTTPException(status.HTTP_401_UNAUTHORIZED, "device_auth_failed")


def _over_limit(redis: Redis, key: str, limit: int, window: int) -> bool:
    redis.set(key, 0, ex=window, nx=True)
    return int(redis.incr(key)) > limit


def _issue_session(
    redis: Redis, settings: Settings, account_id: uuid.UUID, device_id: uuid.UUID
) -> schemas.Session:
    token = security.new_token()
    redis.set(
        f"at:{security.keyed_hash(settings.token_secret, 'access', token)}",
        f"{account_id}:{device_id}",
        ex=settings.access_token_ttl_seconds,
    )
    return schemas.Session(
        access_token=token,
        expires_in=settings.access_token_ttl_seconds,
        account_id=account_id,
        device_id=device_id,
    )


@router.post(
    "/otp/request",
    status_code=status.HTTP_202_ACCEPTED,
    response_model=schemas.OtpRequestAccepted,
)
def request_otp(
    body: schemas.OtpRequest,
    request: Request,
    background: BackgroundTasks,
    settings: SettingsDep,
    redis: RedisDep,
    mailer: MailerDep,
) -> schemas.OtpRequestAccepted:
    """Email a 6-digit code. Same response for every address: sign-in and sign-up are one flow."""
    email_key = security.email_hmac(settings.otp_pepper, body.email).hex()
    client_ip = request.client.host if request.client else "unknown"
    ip_key = security.keyed_hash(settings.token_secret, "ip", client_ip)
    window = settings.otp_rate_window_seconds
    if _over_limit(redis, f"rl:otp:ip:{ip_key}", settings.otp_requests_per_ip, window) or (
        _over_limit(redis, f"rl:otp:email:{email_key}", settings.otp_requests_per_email, window)
    ):
        log.info("otp request rate-limited")
        raise _RATE_LIMITED

    code = security.new_code()
    otp_key = f"otp:{email_key}"
    with redis.pipeline() as pipe:
        pipe.delete(otp_key)
        pipe.hset(
            otp_key,
            mapping={"h": security.keyed_hash(settings.token_secret, f"otp|{email_key}", code)},
        )
        pipe.hset(otp_key, "attempts", 0)
        pipe.expire(otp_key, settings.otp_ttl_seconds)
        pipe.execute()
    # Sent after the response so timing never depends on the mail server.
    background.add_task(mailer.send_sign_in_code, security.normalise_email(body.email), code)
    log.info("otp issued")
    return schemas.OtpRequestAccepted()


@router.post("/otp/verify", response_model=schemas.Session)
def verify_otp(
    body: schemas.OtpVerify, settings: SettingsDep, redis: RedisDep, db: DbDep
) -> schemas.Session:
    """Check the code (5 tries, single use), then find/create the account and bind this phone."""
    try:
        _, device_der = security.load_device_key(body.device_public_key)
    except security.InvalidDeviceKey as exc:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "invalid_device_key") from exc

    email_hmac = security.email_hmac(settings.otp_pepper, body.email)
    email_key = email_hmac.hex()
    otp_key = f"otp:{email_key}"
    stored = redis.hget(otp_key, "h")
    if stored is None:
        raise _INVALID_CODE
    if int(redis.hincrby(otp_key, "attempts", 1)) > settings.otp_max_attempts:
        log.info("otp locked after too many attempts")
        raise _TOO_MANY_ATTEMPTS
    candidate = security.keyed_hash(settings.token_secret, f"otp|{email_key}", body.code)
    if not hmac.compare_digest(stored.decode(), candidate):
        log.info("otp mismatch")
        raise _INVALID_CODE
    if redis.delete(otp_key) == 0:  # another request used it first: single use
        raise _INVALID_CODE

    db.execute(insert(Account).values(email_hmac=email_hmac).on_conflict_do_nothing())
    account = db.scalars(select(Account).where(Account.email_hmac == email_hmac)).one()
    if account.status != "active":
        db.rollback()
        raise HTTPException(status.HTTP_403_FORBIDDEN, "account_suspended")

    fingerprint = security.key_fingerprint(device_der)
    device = db.scalars(select(Device).where(Device.key_fingerprint == fingerprint)).first()
    if device is not None and (device.account_id != account.id or device.revoked_at):
        db.rollback()
        raise HTTPException(status.HTTP_409_CONFLICT, "device_key_in_use")
    if device is None:
        device = Device(account_id=account.id, public_key=device_der, key_fingerprint=fingerprint)
        db.add(device)
        db.flush()
        audit.record(db, "device.registered", actor=account.id, target=f"device:{device.id}")
    else:
        device.last_seen_at = datetime.now(UTC)
    audit.record(db, "auth.otp_verified", actor=account.id, target=f"device:{device.id}")
    db.commit()
    log.info("otp verified")
    return _issue_session(redis, settings, account.id, device.id)


@router.post("/device/challenge", response_model=schemas.DeviceChallenge)
def device_challenge(
    body: schemas.DeviceChallengeRequest, settings: SettingsDep, redis: RedisDep
) -> schemas.DeviceChallenge:
    """Hand out a single-use nonce for the phone to sign. Issued for any device ID (no probing)."""
    nonce = security.new_token()
    redis.set(
        f"dc:{security.keyed_hash(settings.token_secret, 'challenge', nonce)}",
        str(body.device_id),
        ex=settings.device_challenge_ttl_seconds,
    )
    return schemas.DeviceChallenge(nonce=nonce, expires_in=settings.device_challenge_ttl_seconds)


@router.post("/device/verify", response_model=schemas.Session)
def device_verify(
    body: schemas.DeviceVerify, settings: SettingsDep, redis: RedisDep, db: DbDep
) -> schemas.Session:
    """Sign in with the phone's Keystore key: no email code needed on a bound device."""
    challenged = redis.getdel(
        f"dc:{security.keyed_hash(settings.token_secret, 'challenge', body.nonce)}"
    )
    if challenged is None or challenged.decode() != str(body.device_id):
        raise _DEVICE_AUTH_FAILED
    device = db.get(Device, body.device_id)
    if device is None or device.revoked_at is not None:
        raise _DEVICE_AUTH_FAILED
    message = security.device_challenge_message(str(body.device_id), body.nonce)
    if not security.verify_device_signature(device.public_key, message, body.signature):
        log.info("device signature rejected")
        raise _DEVICE_AUTH_FAILED
    account = db.get(Account, device.account_id)
    if account is None or account.status != "active":
        raise _DEVICE_AUTH_FAILED

    device.last_seen_at = datetime.now(UTC)
    audit.record(db, "auth.device_signin", actor=account.id, target=f"device:{device.id}")
    db.commit()
    return _issue_session(redis, settings, account.id, device.id)


# Accounts banned by an admin (P2-W4-helper-ban): their live tokens stop working at once.
# Kept in sync with app.moderation.service.BANNED_KEY.
BANNED_ACCOUNTS_KEY = "banned_accounts"


@dataclass(frozen=True)
class CurrentSession:
    account_id: uuid.UUID
    device_id: uuid.UUID


def session_from_token(settings: Settings, redis: Redis, token: str) -> CurrentSession | None:
    """Look up a live access token. Used by the bearer dependency and the relay WebSocket."""
    if not token:
        return None
    value = redis.get(f"at:{security.keyed_hash(settings.token_secret, 'access', token)}")
    if value is None:
        return None
    account_id, device_id = value.decode().split(":")
    if redis.sismember(BANNED_ACCOUNTS_KEY, account_id):
        return None  # banned: HTTP calls get 401 and the relay socket closes
    return CurrentSession(uuid.UUID(account_id), uuid.UUID(device_id))


def get_current_session(
    settings: SettingsDep,
    redis: RedisDep,
    authorization: Annotated[str | None, Header()] = None,
) -> CurrentSession:
    """Dependency for protected endpoints (contacts, journeys...): `Authorization: Bearer <t>`."""
    scheme, _, token = (authorization or "").partition(" ")
    session = session_from_token(settings, redis, token) if scheme.lower() == "bearer" else None
    if session is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "not_authenticated")
    return session


CurrentSessionDep = Annotated[CurrentSession, Depends(get_current_session)]


@router.put("/device/e2e-keys", response_model=schemas.E2EKeys)
def upload_e2e_keys(
    body: schemas.E2EKeysUpload, session: CurrentSessionDep, db: DbDep
) -> schemas.E2EKeys:
    """Publish this device's X25519 + Ed25519 public keys for E2E location sharing.

    Replaces any earlier keys and issues a new key_id, so contacts can tell keys apart.
    """
    try:
        x25519 = security.load_raw_32_byte_key(body.x25519_public_key)
        ed25519 = security.load_raw_32_byte_key(body.ed25519_public_key)
    except security.InvalidDeviceKey as exc:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "invalid_e2e_key") from exc
    if x25519 == bytes(32):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "invalid_e2e_key")

    key_id = uuid.uuid4()
    db.execute(
        insert(DeviceE2EKeys)
        .values(
            device_id=session.device_id,
            key_id=key_id,
            x25519_public_key=x25519,
            ed25519_public_key=ed25519,
        )
        .on_conflict_do_update(
            index_elements=[DeviceE2EKeys.device_id],
            set_={
                "key_id": key_id,
                "x25519_public_key": x25519,
                "ed25519_public_key": ed25519,
                "updated_at": datetime.now(UTC),
            },
        )
    )
    audit.record(
        db, "device.e2e_keys_set", actor=session.account_id, target=f"device:{session.device_id}"
    )
    db.commit()
    return schemas.E2EKeys(
        key_id=key_id,
        x25519_public_key=base64.b64encode(x25519).decode(),
        ed25519_public_key=base64.b64encode(ed25519).decode(),
    )


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
def logout(
    session: CurrentSessionDep,
    settings: SettingsDep,
    redis: RedisDep,
    db: DbDep,
    authorization: Annotated[str | None, Header()] = None,
) -> None:
    """Sign this phone out: end the token and retire its device key (the app makes a new one).

    Also takes the person off duty as a responder or companion, so nobody is matched to a phone
    that has signed out.
    """
    from app.matching import nearby  # lazy: matching imports this module
    from app.walks.service import clear_presence

    _, _, token = (authorization or "").partition(" ")
    redis.delete(f"at:{security.keyed_hash(settings.token_secret, 'access', token)}")
    device = db.get(Device, session.device_id)
    if device is not None and device.revoked_at is None:
        device.revoked_at = datetime.now(UTC)
    nearby.clear_presence(redis, session.account_id)
    clear_presence(redis, session.account_id)
    audit.record(db, "auth.logout", actor=session.account_id, target=f"device:{session.device_id}")
    db.commit()
