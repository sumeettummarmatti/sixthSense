"""Alert channels a contact sets up (P2-W4): FCM push token, Telegram chat, opt-in email.

All stored values are encrypted with DATA_KEY. The alert email must be the contact's own
sign-in email (checked by HMAC), so nobody can point alerts at someone else's inbox.
"""

from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Response, status

from app.core import audit, crypto
from app.identity import security
from app.identity.models import Account, Device
from app.identity.router import CurrentSessionDep, DbDep, RedisDep, SettingsDep
from app.notification import schemas, signing
from app.notification.channels import Message, Senders, get_senders
from app.notification.models import AlertChannels

router = APIRouter(prefix="/notifications", tags=["notification"])

SendersDep = Annotated[Senders, Depends(get_senders)]
TELEGRAM_LINK_TTL = 600


def _channels(db: DbDep, account_id) -> AlertChannels:
    return db.get(AlertChannels, account_id) or AlertChannels(account_id=account_id)


@router.get("/signing-keys", response_model=schemas.SigningKeys)
def signing_public_keys(settings: SettingsDep) -> schemas.SigningKeys:
    """Public keys that sign push alerts. No sign-in: the app can also bundle the current one."""
    keys = signing.signing_keys(settings.alert_signing_key, settings.alert_signing_key_previous)
    return schemas.SigningKeys(
        keys=[
            schemas.SigningKey(key_id=key.key_id, ed25519_public_key=key.public_b64())
            for key in keys
        ]
    )


@router.get("/channels", response_model=schemas.ChannelStatus)
def channel_status(
    session: CurrentSessionDep, db: DbDep, senders: SendersDep
) -> schemas.ChannelStatus:
    channels = db.get(AlertChannels, session.account_id)
    device = db.get(Device, session.device_id)
    return schemas.ChannelStatus(
        push=bool(device and device.fcm_token_enc),
        telegram=bool(channels and channels.telegram_chat_id_enc),
        email=bool(channels and channels.email_enc),
        push_available=senders.push.configured(),
        telegram_available=senders.telegram.configured(),
    )


@router.put("/push-token", status_code=status.HTTP_204_NO_CONTENT)
def set_push_token(body: schemas.PushToken, session: CurrentSessionDep, db: DbDep) -> Response:
    """The app sends its FCM registration token after sign-in and whenever FCM rotates it."""
    device = db.get(Device, session.device_id)
    if device is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "not_authenticated")
    device.fcm_token_enc = crypto.encrypt(body.fcm_token)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.delete("/push-token", status_code=status.HTTP_204_NO_CONTENT)
def clear_push_token(session: CurrentSessionDep, db: DbDep) -> Response:
    device = db.get(Device, session.device_id)
    if device is not None:
        device.fcm_token_enc = None
        db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/telegram/link", response_model=schemas.TelegramLink)
def telegram_link(
    session: CurrentSessionDep, settings: SettingsDep, redis: RedisDep, senders: SendersDep
) -> schemas.TelegramLink:
    """A one-time t.me link. Opening it and pressing Start links that chat to this account."""
    bot_username = settings.telegram_bot_username.strip().lstrip("@")
    if not senders.telegram.configured() or not bot_username:
        raise HTTPException(status.HTTP_409_CONFLICT, "telegram_not_configured")
    token = security.new_token()
    redis.set(
        f"tg:{security.keyed_hash(settings.token_secret, 'telegram-link', token)}",
        str(session.account_id),
        ex=TELEGRAM_LINK_TTL,
    )
    return schemas.TelegramLink(
        url=f"https://t.me/{bot_username}?start={token}",
        expires_in=TELEGRAM_LINK_TTL,
    )


@router.delete("/telegram", status_code=status.HTTP_204_NO_CONTENT)
def unlink_telegram(session: CurrentSessionDep, db: DbDep) -> Response:
    channels = db.get(AlertChannels, session.account_id)
    if channels is not None:
        channels.telegram_chat_id_enc = None
        channels.updated_at = datetime.now(UTC)
        db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.put("/email", status_code=status.HTTP_204_NO_CONTENT)
def set_alert_email(
    body: schemas.AlertEmail, session: CurrentSessionDep, settings: SettingsDep, db: DbDep
) -> Response:
    """Opt in to alert emails. Only your own sign-in email is accepted."""
    account = db.get(Account, session.account_id)
    if account is None or account.email_hmac != security.email_hmac(
        settings.otp_pepper, body.email
    ):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "email_must_match_sign_in")
    channels = _channels(db, session.account_id)
    channels.email_enc = crypto.encrypt(security.normalise_email(body.email))
    channels.updated_at = datetime.now(UTC)
    db.add(channels)
    audit.record(db, "alerts.email_enabled", actor=session.account_id)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.delete("/email", status_code=status.HTTP_204_NO_CONTENT)
def clear_alert_email(session: CurrentSessionDep, db: DbDep) -> Response:
    channels = db.get(AlertChannels, session.account_id)
    if channels is not None:
        channels.email_enc = None
        channels.updated_at = datetime.now(UTC)
        db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


def link_telegram_chats(db, redis, settings, senders: Senders) -> int:
    """Worker step: read new bot messages and link chats that sent '/start <token>'."""
    if not senders.telegram.configured():
        return 0
    offset = int(redis.get("tg:offset") or 0)
    linked = 0
    for update in senders.telegram.get_updates(offset):  # type: ignore[attr-defined]
        redis.set("tg:offset", update["update_id"] + 1)
        message = update.get("message") or {}
        text, chat = message.get("text", ""), message.get("chat", {})
        if "id" not in chat or not (text == "/start" or text.startswith("/start ")):
            continue
        token = text.removeprefix("/start").strip()
        # A bare "/start" (no link code) gets the same "open the app" reply as an old link.
        account_id = (
            redis.getdel(f"tg:{security.keyed_hash(settings.token_secret, 'telegram-link', token)}")
            if token
            else None
        )
        if account_id is None:
            senders.telegram.send(str(chat["id"]), _TELEGRAM_EXPIRED)
            continue
        channels = _channels(db, account_id.decode())
        channels.telegram_chat_id_enc = crypto.encrypt(str(chat["id"]))
        channels.updated_at = datetime.now(UTC)
        db.add(channels)
        audit.record(db, "alerts.telegram_linked", actor=channels.account_id)
        db.commit()
        senders.telegram.send(str(chat["id"]), _TELEGRAM_LINKED)
        linked += 1
    return linked


_TELEGRAM_LINKED = Message(
    "SixthSense", "Linked. You'll get safety alerts here for people who chose you as a contact."
)
_TELEGRAM_EXPIRED = Message(
    "SixthSense", "This link has expired. Open SixthSense and tap 'Get alerts on Telegram' again."
)
