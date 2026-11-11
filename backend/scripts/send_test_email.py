"""Check real email sending (ALL-W1-demo-real-email).

Uses the SMTP_* settings from .env and sends one test email, so you know sign-in codes will
reach a real inbox before you demo.

    cd backend && uv run python scripts/send_test_email.py you@example.com
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # run from backend/ or anywhere

from app.core.config import get_settings  # noqa: E402
from app.identity.mailer import SmtpMailer  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("to", help="address to send the test email to")
    args = parser.parse_args()

    settings = get_settings()
    mode = "SSL" if settings.smtp_ssl else ("STARTTLS" if settings.smtp_starttls else "no TLS")
    print(f"Sending via {settings.smtp_host}:{settings.smtp_port} ({mode}) ...")
    if settings.smtp_host in ("localhost", "127.0.0.1"):
        print("Note: SMTP_HOST is local, so this goes to Mailpit (http://localhost:8025),")
        print("      not a real inbox.")

    ok = SmtpMailer().send(
        args.to,
        "SixthSense test email",
        "If you can read this, SixthSense can send real sign-in codes and alerts.",
    )
    if ok:
        print("OK: sent. Check the inbox (and the spam folder).")
        return 0
    print(
        "FAILED: see the warning above for the error type.\n"
        "  SMTPAuthenticationError -> wrong SMTP_USERNAME or not a Gmail App password\n"
        "  timeout / ConnectionRefused -> wrong SMTP_HOST/SMTP_PORT, or network blocks it\n"
        "  SSLError -> use port 587 with SMTP_STARTTLS=true (or 465 with SMTP_SSL=true)"
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
