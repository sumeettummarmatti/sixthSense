import logging
import smtplib
import ssl
from email.message import EmailMessage
from functools import lru_cache

from app.core.config import get_settings

log = logging.getLogger(__name__)


class SmtpMailer:
    """Sends sign-in codes over plain SMTP: Mailpit locally, any free SMTP account for real."""

    def send_sign_in_code(self, to: str, code: str) -> None:
        settings = get_settings()
        self.send(
            to,
            f"{code} is your SixthSense sign-in code",
            f"Your SixthSense sign-in code is {code}.\n\n"
            f"It expires in {settings.otp_ttl_seconds // 60} minutes and works once.\n"
            "If you didn't ask for it, ignore this email. Nobody at SixthSense will ask for it.",
        )

    def send(self, to: str, subject: str, body: str) -> bool:
        settings = get_settings()
        message = EmailMessage()
        message["From"] = settings.smtp_from
        message["To"] = to
        message["Subject"] = subject
        message.set_content(body)
        # Verified TLS: smtplib's default context skips certificate checks.
        tls = ssl.create_default_context()
        try:
            if settings.smtp_ssl:
                connection = smtplib.SMTP_SSL(
                    settings.smtp_host, settings.smtp_port, timeout=10, context=tls
                )
            else:
                connection = smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=10)
            with connection as smtp:
                if settings.smtp_starttls and not settings.smtp_ssl:
                    smtp.starttls(context=tls)
                if settings.smtp_username:
                    smtp.login(settings.smtp_username, settings.smtp_password)
                smtp.send_message(message)
        except (OSError, smtplib.SMTPException) as exc:
            # Never include the address or content; the exception type is enough to debug.
            log.warning("email failed: %s", type(exc).__name__)
            return False
        return True


@lru_cache
def get_mailer() -> SmtpMailer:
    return SmtpMailer()
