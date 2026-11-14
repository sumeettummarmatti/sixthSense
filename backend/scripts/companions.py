"""Pilot companion approval (P3-W3). Companions pass the in-app DEMO verification (a stub that
always passes) and are then approved here by hand, after checking the person in real life
(campus ID card, in person). No ID is stored. Names are the profile's first name.

    cd backend && uv run python scripts/companions.py list
    cd backend && uv run python scripts/companions.py approve Riya
    cd backend && uv run python scripts/companions.py approve-all      # demo only
    cd backend && uv run python scripts/companions.py revoke Riya
"""

import argparse
import sys
from datetime import UTC, datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # run from backend/ or anywhere

from sqlalchemy import select  # noqa: E402

from app.core import audit  # noqa: E402
from app.core.db import SessionLocal  # noqa: E402
from app.profiles.models import Profile  # noqa: E402
from app.walks.models import CompanionProfile  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("action", choices=["list", "approve", "approve-all", "revoke"])
    parser.add_argument("name", nargs="?", help="first name (case-insensitive)")
    args = parser.parse_args()
    now = datetime.now(UTC)
    with SessionLocal() as db:
        rows = db.execute(
            select(CompanionProfile, Profile)
            .join(Profile, Profile.account_id == CompanionProfile.account_id)
            .order_by(CompanionProfile.verified_at)
        ).all()
        if args.action == "list":
            if not rows:
                print("No companion applications yet.")
            for c, p in rows:
                print(
                    f"{c.status:9} {p.first_name:20} verified {c.verified_method} "
                    f"{c.verified_at:%d %b %H:%M}"
                )
            return
        if args.action == "approve-all":
            chosen = [c for c, _ in rows if c.status == "pending"]
            names = {c.account_id: p.first_name for c, p in rows}
        else:
            if not args.name:
                parser.error("give the first name")
            matches = [(c, p) for c, p in rows if p.first_name.lower() == args.name.lower()]
            if not matches:
                sys.exit(f"No companion called {args.name!r}. Try: list")
            chosen = [c for c, _ in matches]
            names = {c.account_id: p.first_name for c, p in matches}
        for c in chosen:
            if args.action == "revoke":
                c.status = "revoked"
            else:
                c.status, c.approved_at = "approved", now
            audit.record(db, f"companion.{c.status}", actor=None, target=f"account:{c.account_id}")
            print(f"{c.status}: {names[c.account_id]}")
        db.commit()


if __name__ == "__main__":
    main()
