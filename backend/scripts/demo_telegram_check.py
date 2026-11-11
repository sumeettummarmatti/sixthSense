"""Demo check (P2-W1-demo-telegram-live): prove a real Telegram alert reaches a contact.

Needs the local stack, the API and the worker running, and TELEGRAM_BOT_TOKEN /
TELEGRAM_BOT_USERNAME in .env. Only one machine may run the worker with that bot token.

    cd backend && uv run python scripts/demo_telegram_check.py [--api http://localhost:8000]

It signs up an owner and a contact (codes read from Mailpit), links the contact to YOUR
Telegram (you open the printed link and press Start), then runs two scenarios and waits for the
worker to report a Telegram delivery: 1) SOS, 2) missed check-in with 1-minute demo timers.
"""

import argparse
import base64
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # run from backend/ or anywhere

import httpx  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat  # noqa: E402
from sqlalchemy import select  # noqa: E402

from app.core.audit import AuditEvent  # noqa: E402
from app.core.db import SessionLocal  # noqa: E402

MAILPIT = "http://localhost:8025"


def wait_for(what: str, check, timeout: float, every: float = 1.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = check()
        if result:
            return result
        time.sleep(every)
    sys.exit(f"FAILED: timed out waiting for {what}")


def sign_up(api: httpx.Client, tag: str) -> dict[str, str]:
    email = f"{tag}{int(time.time() * 1000)}@demo-college.edu"
    api.post("/auth/otp/request", json={"email": email}).raise_for_status()

    def code():
        for message in httpx.get(f"{MAILPIT}/api/v1/messages").json()["messages"]:
            if message["To"][0]["Address"] == email:
                return re.search(r"\d{6}", message["Subject"]).group()
        return None

    key = ec.generate_private_key(ec.SECP256R1()).public_key()
    public = base64.b64encode(key.public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo))
    session = api.post(
        "/auth/otp/verify",
        json={
            "email": email,
            "code": wait_for("sign-in email", code, 20),
            "device_public_key": public.decode(),
        },
    )
    session.raise_for_status()
    return {"Authorization": f"Bearer {session.json()['access_token']}"}


def telegram_sends_since(since: int) -> int:
    with SessionLocal() as db:
        return len(
            db.scalars(
                select(AuditEvent.id).where(
                    AuditEvent.action == "escalation.sent.telegram", AuditEvent.id > since
                )
            ).all()
        )


def last_audit_id() -> int:
    with SessionLocal() as db:
        return db.scalar(select(AuditEvent.id).order_by(AuditEvent.id.desc()).limit(1)) or 0


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--api", default="http://localhost:8000")
    args = parser.parse_args()
    api = httpx.Client(base_url=args.api, timeout=10)

    print("1. Signing up an owner and a contact (codes come from Mailpit)...")
    owner, contact = sign_up(api, "owner"), sign_up(api, "contact")
    invite = api.post("/contacts/invites", json={"owner_label": "Priya"}, headers=owner).json()
    api.post(
        "/contacts/invites/accept", json={"invite_token": invite["invite_token"]}, headers=contact
    ).raise_for_status()

    link = api.post("/notifications/telegram/link", headers=contact)
    if link.status_code == 409:
        sys.exit("FAILED: telegram_not_configured. Set TELEGRAM_BOT_TOKEN/USERNAME and restart.")
    link.raise_for_status()
    print(
        "\n2. Open this on your phone or Telegram Desktop and press Start:\n\n"
        f"   {link.json()['url']}\n"
    )
    wait_for(
        "you to press Start (is the worker running?)",
        lambda: api.get("/notifications/channels", headers=contact).json()["telegram"],
        timeout=600,
        every=2,
    )
    print("   Linked. The bot should have replied 'Linked...'.")

    print("\n3. Scenario A: SOS")
    since = last_audit_id()
    journey = api.post("/journeys", json={}, headers=owner).json()
    started = time.time()
    api.post(f"/journeys/{journey['id']}/sos", json={}, headers=owner).raise_for_status()
    wait_for("the SOS Telegram alert", lambda: telegram_sends_since(since), timeout=60)
    print(f"   Telegram accepted the SOS alert after {time.time() - started:.1f}s.")
    print("   Check Telegram: 'URGENT: Priya may need help now' with a verification code.")
    escalation = api.get("/escalations/active", headers=contact).json()["escalations"][0]
    print(f"   The app shows verification code {escalation['verification_code']}: compare it.")
    api.post(f"/escalations/{escalation['id']}/resolve", headers=contact).raise_for_status()
    print("   Resolved as the contact (journey ended).")

    print(
        "\n4. Scenario B: missed check-in "
        "(demo timers: 1-minute check-in, no grace, 1-minute prompt)"
    )
    api.put(
        "/journeys/protocol",
        json={
            "check_in_interval_min": 1,
            "check_in_grace_min": 0,
            "prompt_timeout_min": 1,
            "contact_response_min": 5,
            "heartbeat_timeout_min": 10,
        },
        headers=owner,
    ).raise_for_status()
    since = last_audit_id()
    journey = api.post("/journeys", json={}, headers=owner).json()
    started = time.time()
    print("   Journey started; not checking in. The alert should arrive in about 2 minutes...")
    wait_for(
        "the missed-check-in Telegram alert",
        lambda: telegram_sends_since(since),
        timeout=240,
        every=3,
    )
    print(f"   Telegram accepted the missed check-in alert after {time.time() - started:.0f}s.")
    print("   Check Telegram: 'Priya missed a safety check-in'.")
    api.post(
        f"/journeys/{journey['id']}/check-in", json={"result": "ok"}, headers=owner
    ).raise_for_status()
    print("   Owner checked in; the contact should get 'All clear' within ~5 s.")
    # End it, or the 1-minute timers keep missing check-ins and alert again.
    api.post(f"/journeys/{journey['id']}/end", headers=owner).raise_for_status()
    print("   Journey ended.")
    print("\nPASSED: both alerts were delivered to Telegram.")


if __name__ == "__main__":
    main()
