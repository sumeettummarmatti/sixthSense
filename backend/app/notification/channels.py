"""Free alert channels: FCM push -> Telegram bot -> email (PLANNER §3b).

Each sender says whether it is configured and returns True when the provider accepted the
message. Messages never contain location; logs never contain targets or message text.
"""

import base64
import json
import logging
import time
from dataclasses import dataclass, field
from functools import lru_cache
from typing import Protocol

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from app.core.config import Settings, get_settings
from app.identity.mailer import SmtpMailer, get_mailer

log = logging.getLogger(__name__)

CHANNEL_ORDER = ("push", "telegram", "email")


@dataclass(frozen=True)
class Message:
    title: str
    body: str
    ack_url: str | None = None
    code: str | None = None  # verification code shown on the same alert in the app (P2-W6)
    data: dict[str, str] = field(default_factory=dict)  # signed alert for push (P2-W6)

    def text(self) -> str:
        link = f"\n\nTap to say you're on it: {self.ack_url}" if self.ack_url else ""
        code = (
            f"\n\nVerification code: {self.code}. The SixthSense app shows the same code on "
            "this alert. If it doesn't, this message is fake."
            if self.code
            else ""
        )
        return f"{self.title}\n{self.body}{link}{code}"


class Sender(Protocol):
    name: str

    def configured(self) -> bool: ...

    def send(self, target: str, message: Message) -> bool: ...


class EmailSender:
    name = "email"

    def __init__(self, mailer: SmtpMailer) -> None:
        self._mailer = mailer

    def configured(self) -> bool:
        return True  # SMTP always set (Mailpit locally)

    def send(self, target: str, message: Message) -> bool:
        return self._mailer.send(target, message.title, message.text())


class TelegramSender:
    """Telegram Bot API over HTTPS. Contacts link a chat by opening t.me/<bot>?start=<token>."""

    name = "telegram"

    # Some networks are slow to open a TLS connection to Telegram (~8 s) and sometimes reset
    # it, so allow a longer connect and retry when connecting fails. Only connect errors are
    # retried: the request was never sent, so a contact can't get the same alert twice.
    CONNECT_ATTEMPTS = 3

    def __init__(self, settings: Settings, client: httpx.Client | None = None) -> None:
        self._token = settings.telegram_bot_token.strip()
        self._client = client or httpx.Client(timeout=httpx.Timeout(15, connect=20))

    def configured(self) -> bool:
        return bool(self._token)

    def _call(self, method: str, payload: dict) -> dict | None:
        url = f"https://api.telegram.org/bot{self._token}/{method}"
        for attempt in range(1, self.CONNECT_ATTEMPTS + 1):
            try:
                body = self._client.post(url, json=payload).json()
                break
            except (httpx.ConnectError, httpx.ConnectTimeout) as exc:
                log.warning(
                    "telegram %s connect failed (%d): %s", method, attempt, type(exc).__name__
                )
                if attempt == self.CONNECT_ATTEMPTS:
                    return None
                time.sleep(attempt)
            except (httpx.HTTPError, ValueError) as exc:
                log.warning("telegram %s failed: %s", method, type(exc).__name__)
                return None
        if not body.get("ok"):
            log.warning("telegram %s rejected: %s", method, body.get("error_code"))
            return None
        return body

    def send(self, target: str, message: Message) -> bool:
        payload = {"chat_id": target, "text": message.text(), "disable_web_page_preview": True}
        return self._call("sendMessage", payload) is not None

    def get_updates(self, offset: int) -> list[dict]:
        body = self._call(
            "getUpdates", {"offset": offset, "timeout": 0, "allowed_updates": ["message"]}
        )
        return body["result"] if body else []


class FcmSender:
    """Firebase Cloud Messaging HTTP v1, authenticated with a service-account key (free tier)."""

    name = "push"
    _SCOPE = "https://www.googleapis.com/auth/firebase.messaging"

    def __init__(self, settings: Settings, client: httpx.Client | None = None) -> None:
        self._project = settings.fcm_project_id
        self._key_file = settings.fcm_service_account_file
        self._client = client or httpx.Client(timeout=10)
        self._access_token: str | None = None
        self._expires_at = 0.0

    def configured(self) -> bool:
        return bool(self._project and self._key_file)

    def _token(self) -> str | None:
        if self._access_token and time.time() < self._expires_at - 60:
            return self._access_token
        try:
            with open(self._key_file) as f:
                account = json.load(f)
            key = serialization.load_pem_private_key(account["private_key"].encode(), None)
            if not isinstance(key, rsa.RSAPrivateKey):
                return None
            now = int(time.time())
            assertion = _rs256_jwt(
                key,
                {
                    "iss": account["client_email"],
                    "scope": self._SCOPE,
                    "aud": account["token_uri"],
                    "iat": now,
                    "exp": now + 3600,
                },
            )
            resp = self._client.post(
                account["token_uri"],
                data={
                    "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                    "assertion": assertion,
                },
            )
            resp.raise_for_status()
            body = resp.json()
        except (OSError, KeyError, ValueError, httpx.HTTPError) as exc:
            log.warning("fcm auth failed: %s", type(exc).__name__)
            return None
        self._access_token = body["access_token"]
        self._expires_at = time.time() + int(body.get("expires_in", 3600))
        return self._access_token

    def send(self, target: str, message: Message) -> bool:
        token = self._token()
        if token is None:
            return False
        payload = {
            "message": {
                "token": target,
                "notification": {"title": message.title, "body": message.body},
                "data": {"ack_url": message.ack_url or "", **message.data},
                "android": {"priority": "high"},
            }
        }
        try:
            resp = self._client.post(
                f"https://fcm.googleapis.com/v1/projects/{self._project}/messages:send",
                json=payload,
                headers={"Authorization": f"Bearer {token}"},
            )
        except httpx.HTTPError as exc:
            log.warning("fcm send failed: %s", type(exc).__name__)
            return False
        if resp.status_code != 200:
            log.warning("fcm send rejected: %s", resp.status_code)
            return False
        return True


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _rs256_jwt(key: rsa.RSAPrivateKey, claims: dict) -> str:
    header = _b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    body = _b64url(json.dumps(claims).encode())
    signing_input = f"{header}.{body}".encode()
    signature = key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
    return f"{header}.{body}.{_b64url(signature)}"


@dataclass
class Senders:
    push: Sender
    telegram: Sender
    email: Sender

    def by_name(self, name: str) -> Sender:
        return getattr(self, name)


def build_senders(settings: Settings, mailer: SmtpMailer) -> Senders:
    return Senders(
        push=FcmSender(settings), telegram=TelegramSender(settings), email=EmailSender(mailer)
    )


@lru_cache
def get_senders() -> Senders:
    """FastAPI/worker dependency; tests override it with fakes."""
    return build_senders(get_settings(), get_mailer())
