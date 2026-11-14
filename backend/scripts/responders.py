"""Responders (P3-W1). There is no approval step: anyone who verifies their identity in the app
(ID + selfie) and applies is a responder. This script lists them and revokes someone after a
complaint (clears their on-duty status, open offers and live location access). No ID is stored.

    cd backend && uv run python scripts/responders.py list
    cd backend && uv run python scripts/responders.py revoke Riya safety_concern
"""

import argparse
import sys
from datetime import UTC, datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # run from backend/ or anywhere

from sqlalchemy import select  # noqa: E402

from app.core.db import SessionLocal  # noqa: E402
from app.core.redis import get_redis  # noqa: E402
from app.matching.models import ResponderProfile  # noqa: E402
from app.verification.eligibility import verified_identity  # noqa: E402
from app.verification.revocation import revoke_responder  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("action", choices=["list", "revoke"])
    parser.add_argument("name", nargs="?", help="display name (case-insensitive)")
    parser.add_argument("reason", nargs="?", help="short lowercase reason code for revocation")
    args = parser.parse_args()
    if args.action == "revoke" and not args.reason:
        parser.error("give a reason code, e.g. safety_concern")
    now = datetime.now(UTC)
    with SessionLocal() as db:
        profiles = list(db.scalars(select(ResponderProfile).order_by(ResponderProfile.applied_at)))
        if args.action == "list":
            if not profiles:
                print("No responders yet.")
            for p in profiles:
                identity = "verified" if verified_identity(db, p.account_id, now) else "unverified"
                state = "revoked" if p.status == "revoked" else "active"
                print(
                    f"{state:8} {identity:10} {p.display_name:20} "
                    f"applied {p.applied_at:%d %b %H:%M}"
                )
            return
        if not args.name:
            parser.error("give the display name")
        chosen = [p for p in profiles if p.display_name.lower() == args.name.lower()]
        if not chosen:
            sys.exit(f"No responder called {args.name!r}. Try: list")
        for p in chosen:
            revoke_responder(db, get_redis(), p.account_id, now, args.reason)
            print(f"revoked: {p.display_name}")
        db.commit()


if __name__ == "__main__":
    main()
