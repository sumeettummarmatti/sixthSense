#!/usr/bin/env python3
"""Write a production .env from .env.example with fresh random secrets.

    python3 deploy/make_env.py api.example.com insight.example.com

Run once per server. It refuses to overwrite an existing .env: changing OTP_PEPPER or
FACE_TEMPLATE_KEY later makes existing accounts and face references unusable.
Email (SMTP_*) and Telegram (TELEGRAM_*) still need your own values afterwards.
"""

import base64
import os
import re
import secrets
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    api_domain, insight_domain = sys.argv[1], sys.argv[2]
    target = ROOT / ".env"
    if target.exists():
        sys.exit(".env already exists; not overwriting it (secrets must stay the same).")

    token = lambda: secrets.token_urlsafe(48)  # noqa: E731
    core_pw, insight_pw = secrets.token_urlsafe(24), secrets.token_urlsafe(24)
    admin_pw = secrets.token_urlsafe(18)
    values = {
        "CORE_DB_PASSWORD": core_pw,
        "CORE_DATABASE_URL": f"postgresql+psycopg://core:{core_pw}@localhost:5434/sixthsense_core",
        "INSIGHT_DB_PASSWORD": insight_pw,
        "INSIGHT_DATABASE_URL": (
            f"postgresql+psycopg://insight:{insight_pw}@localhost:5433/sixthsense_insight"
        ),
        "REPORT_PEPPER": token(),
        "OTP_PEPPER": token(),
        "TOKEN_SECRET": token(),
        "IDENTITY_HMAC_SECRET": token(),
        "FACE_TEMPLATE_KEY": token(),
        "DATA_KEY": token(),
        "ALERT_SIGNING_KEY": base64.b64encode(os.urandom(32)).decode(),
        "PUBLIC_BASE_URL": f"https://{api_domain}",
        "FACE_MATCHER": "compreface",
        "FACE_CHECK_PROVIDER": "auto",
        "ADMIN_USERNAME": "admin",
        "ADMIN_PASSWORD": admin_pw,
        "ENV": "production",
    }
    lines = []
    for line in (ROOT / ".env.example").read_text().splitlines():
        match = re.match(r"^([A-Z_]+)=", line)
        if match and match.group(1) in values:
            line = f"{match.group(1)}={values.pop(match.group(1))}"
        lines.append(line)
    for key, value in values.items():  # anything .env.example did not list
        lines.append(f"{key}={value}")
    lines.append(f"# Domains used by deploy/install.sh: API {api_domain}, Insight {insight_domain}")
    target.write_text("\n".join(lines) + "\n")
    target.chmod(0o600)
    print(f"Wrote {target} (readable by its owner only).")
    print(f"Admin feedback page: https://{api_domain}/admin/feedback  user: admin  "
          f"password: {admin_pw}")


if __name__ == "__main__":
    main()
