"""Admin access to raw journey/walk feedback (P2-W3). Also on the admin page /admin/feedback
(needs ADMIN_PASSWORD). List it, or export it as CSV for analysis. The export holds ids,
stars, chips and notes only: no location, no names. Every run is in the append-only audit log.

    cd backend && uv run python scripts/feedback.py list
    cd backend && uv run python scripts/feedback.py export feedback.csv
"""

import argparse
import csv
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # run from backend/ or anywhere

from app.core import audit  # noqa: E402
from app.core.db import SessionLocal  # noqa: E402
from app.feedback.export import COLUMNS, rows  # noqa: E402, F401  (COLUMNS used by tests)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("action", choices=["list", "export"])
    parser.add_argument("file", nargs="?", help="CSV file to write (export)")
    args = parser.parse_args(argv)
    if args.action == "export" and not args.file:
        parser.error("give the CSV file to write")
    with SessionLocal() as db:
        data = rows(db)
        audit.record(db, f"feedback.admin_{args.action}", actor=None, target=f"rows:{len(data)}")
        db.commit()
    if args.action == "list":
        if not data:
            print("No feedback yet.")
        for row in data:
            companion = f" companion {row['companion_stars']}*" if row["companion_stars"] else ""
            print(
                f"{row['created_at'][:16]} route {row['route_stars']}*{companion} "
                f"[{row['chips']}] {row['note'][:60]}"
            )
        return
    with open(args.file, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=COLUMNS)
        writer.writeheader()
        writer.writerows(data)
    print(f"Wrote {len(data)} rows to {args.file}")


if __name__ == "__main__":
    main()
