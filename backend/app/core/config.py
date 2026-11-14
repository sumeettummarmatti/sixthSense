from functools import lru_cache

from pydantic import Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

_DEV_SECRET_PREFIX = "dev-only-"  # noqa: S105  (marker, not a secret)


class Settings(BaseSettings):
    """Core-zone settings. The Core service never receives Insight DB credentials (ADR-1)."""

    model_config = SettingsConfigDict(env_file=("../.env", ".env"), extra="ignore")

    env: str = "dev"
    core_database_url: str = (
        "postgresql+psycopg://core:core_dev_password@localhost:5434/sixthsense_core"
    )
    redis_url: str = "redis://localhost:6379/0"
    nats_url: str = "nats://localhost:4222"

    # Sign-in (P2-W1). Accounts are keyed by HMAC(otp_pepper, email); tokens and codes are
    # stored as HMAC(token_secret, value), so a Redis dump reveals neither.
    otp_pepper: str = "dev-only-pepper-change-me"
    token_secret: str = "dev-only-token-secret-change-me"  # noqa: S105  (rejected outside dev)
    otp_ttl_seconds: int = 600
    otp_max_attempts: int = 5
    otp_requests_per_email: int = 3
    otp_requests_per_ip: int = 10
    otp_rate_window_seconds: int = 600
    access_token_ttl_seconds: int = 900
    device_challenge_ttl_seconds: int = 120

    # Verification (P3-W2): only responders/companions need identity verification.
    identity_hmac_secret: str = "dev-only-identity-hmac-secret-change-me"  # noqa: S105
    identity_hmac_key_version: int = 1
    verification_mock_scenarios: bool = False
    verification_valid_days: int = 365
    key_rotation_cooldown_hours: int = 24
    verification_max_attempts_per_day: int = 3
    compreface_api_url: str = "http://localhost:8003"
    compreface_api_key: str = ""
    compreface_match_threshold: float = Field(default=0.8, ge=0.0, le=1.0)
    face_template_key: str = Field(default="dev-only-face-template-key-change-me", min_length=32)

    # Trusted contacts (P2-W2)
    max_trusted_contacts: int = 5  # accepted + pending invites
    contact_invite_ttl_seconds: int = 172_800  # 48 h
    contact_invites_per_hour: int = 10
    invite_base_url: str = "https://sixthsense.app/invite"

    # Alerts (P2-W4). DATA_KEY encrypts the few things we must keep to reach a contact
    # (FCM token, Telegram chat id, opt-in alert email). All channels are free.
    data_key: str = "dev-only-data-key-change-me"
    public_base_url: str = "http://localhost:8000"  # where contacts open acknowledgement links
    fcm_project_id: str = ""
    fcm_service_account_file: str = ""  # path to the Firebase service-account JSON (never commit)
    telegram_bot_token: str = ""
    telegram_bot_username: str = ""
    ladder_step_seconds: int = 60  # push -> telegram -> email, one step per minute
    ladder_cycle_seconds: int = 300  # then repeat the ladder every 5 minutes
    ladder_max_cycles: int = 12  # for about an hour, or until someone acknowledges

    # Nearby responders (P3-W1). Rough areas only (~110 m grid), kept in Redis for minutes.
    responder_auto_approve: bool = False  # pilot: approve by hand with scripts/responders.py
    responder_presence_ttl_seconds: int = 300  # on-duty phones refresh every minute
    responder_radii_m: tuple[int, ...] = (500, 1000, 2000)  # grows if nobody says "I'm going"
    responder_radius_step_seconds: int = 60
    responder_max_offers: int = 5  # people alerted per SOS, nearest first
    responder_precise_limit: int = 2  # how many "I'm going" get precise live location
    alert_area_ttl_seconds: int = 600

    # Signed alerts (P2-W6): base64 32-byte Ed25519 seed. The previous key stays published
    # after a rotation so apps holding older alerts can still verify them.
    alert_signing_key: str = "dev-only-alert-signing-key"
    alert_signing_key_previous: str = ""

    smtp_host: str = "localhost"
    smtp_port: int = 1025
    smtp_username: str = ""
    smtp_password: str = ""
    smtp_starttls: bool = False
    # Implicit TLS from the first byte (port 465). Use either this or STARTTLS (587), not both.
    smtp_ssl: bool = False
    smtp_from: str = "SixthSense <no-reply@sixthsense.local>"

    @model_validator(mode="after")
    def _no_dev_secrets_outside_dev(self) -> "Settings":
        if self.env not in ("dev", "test"):
            for name in (
                "otp_pepper",
                "token_secret",
                "data_key",
                "alert_signing_key",
                "identity_hmac_secret",
                "face_template_key",
            ):
                if getattr(self, name).startswith(_DEV_SECRET_PREFIX):
                    raise ValueError(f"{name.upper()} must be a real secret when ENV={self.env}")
        return self


@lru_cache
def get_settings() -> Settings:
    return Settings()
