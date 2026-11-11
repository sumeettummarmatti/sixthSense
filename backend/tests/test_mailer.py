import smtplib
import ssl

import pytest

from app.core.config import get_settings
from app.identity import mailer
from app.identity.mailer import SmtpMailer


class FakeSmtp:
    instances: list["FakeSmtp"] = []

    def __init__(self, host, port, timeout=None, context=None):
        self.host, self.port, self.context = host, port, context
        self.starttls_context = None
        self.login_args = None
        self.sent = []
        FakeSmtp.instances.append(self)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def starttls(self, context=None):
        self.starttls_context = context

    def login(self, user, password):
        self.login_args = (user, password)

    def send_message(self, message):
        self.sent.append(message)


@pytest.fixture
def smtp_env(monkeypatch):
    FakeSmtp.instances = []
    monkeypatch.setattr(smtplib, "SMTP", FakeSmtp)
    monkeypatch.setattr(smtplib, "SMTP_SSL", FakeSmtp)

    def configure(**values):
        for key, value in values.items():
            monkeypatch.setenv(key, str(value))
        get_settings.cache_clear()

    yield configure
    get_settings.cache_clear()


def test_starttls_uses_verified_context_and_logs_in(smtp_env) -> None:
    smtp_env(
        SMTP_HOST="smtp.gmail.com",
        SMTP_PORT=587,
        SMTP_STARTTLS="true",
        SMTP_SSL="false",
        SMTP_USERNAME="team@gmail.com",
        SMTP_PASSWORD="app-password",
    )
    assert SmtpMailer().send("a@example.com", "s", "b") is True
    smtp = FakeSmtp.instances[-1]
    assert isinstance(smtp.starttls_context, ssl.SSLContext)
    assert smtp.starttls_context.verify_mode == ssl.CERT_REQUIRED
    assert smtp.starttls_context.check_hostname is True
    assert smtp.login_args == ("team@gmail.com", "app-password")
    assert len(smtp.sent) == 1


def test_implicit_ssl_uses_smtp_ssl_with_verified_context(smtp_env) -> None:
    smtp_env(SMTP_HOST="smtp.gmail.com", SMTP_PORT=465, SMTP_SSL="true", SMTP_STARTTLS="true")
    assert SmtpMailer().send("a@example.com", "s", "b") is True
    smtp = FakeSmtp.instances[-1]
    assert smtp.context is not None and smtp.context.verify_mode == ssl.CERT_REQUIRED
    assert smtp.starttls_context is None  # no STARTTLS on an already-encrypted connection


def test_failure_returns_false_without_leaking_address(smtp_env, monkeypatch) -> None:
    smtp_env(SMTP_HOST="smtp.gmail.com", SMTP_PORT=587, SMTP_STARTTLS="true", SMTP_SSL="false")

    def refuse(*args, **kwargs):
        raise smtplib.SMTPAuthenticationError(535, b"bad credentials")

    monkeypatch.setattr(FakeSmtp, "login", refuse)
    monkeypatch.setenv("SMTP_USERNAME", "team@gmail.com")
    get_settings.cache_clear()
    logged: list[str] = []
    monkeypatch.setattr(mailer.log, "warning", lambda msg, *a: logged.append(msg % a))
    assert SmtpMailer().send("victim@example.com", "s", "b") is False
    assert logged == ["email failed: SMTPAuthenticationError"]  # type only, no address
