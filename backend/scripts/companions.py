"""Walk With Me companions (P3-W3). There is no approval step: anyone who verifies their identity
in the app (ID + selfie) and joins as a companion can be found by travellers. This script lists
companions and revokes someone after a complaint (no longer findable, open requests declined, an
accepted walk ends and its live location stops). No ID is stored. Names are profile first names.

    cd backend && uv run python scripts/companions.py list
    cd backend && uv run python scripts/companions.py revoke Riya
"""

import argparse
import sys
from datetime import UTC, datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # run from backend/ or anywhere

from sqlalchemy import select  # noqa: E402

from app.core.db import SessionLocal  # noqa: E402
from app.core.redis import get_redis  # noqa: E402
from app.profiles.models import Profile  # noqa: E402
from app.verification.eligibility import verified_identity  # noqa: E402
from app.walks.models import CompanionProfile  # noqa: E402
from app.walks.service import revoke_companion  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("action", choices=["list", "revoke"])
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
                print("No companions yet.")
            for c, p in rows:
                identity = "verified" if verified_identity(db, c.account_id, now) else "unverified"
                state = "revoked" if c.status == "revoked" else "active"
                joined = f"{c.verified_at:%d %b %H:%M}"
                print(f"{state:8} {identity:10} {p.first_name:20} joined {joined}")
            return
        if not args.name:
            parser.error("give the first name")
        matches = [(c, p) for c, p in rows if p.first_name.lower() == args.name.lower()]
        if not matches:
            sys.exit(f"No companion called {args.name!r}. Try: list")
        for c, p in matches:
            revoke_companion(db, get_redis(), c.account_id, now)
            print(f"revoked: {p.first_name}")
        db.commit()


if __name__ == "__main__":
    main()
