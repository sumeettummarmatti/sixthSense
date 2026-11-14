"""Admin feedback page (P2-W3-feedback-admin-page): every rating in one table, plus a CSV.

Behind HTTP Basic auth (ADMIN_USERNAME / ADMIN_PASSWORD); off (404) while no password is set.
Shows what the feedback table holds and nothing more: ids, stars, chips, note. It never joins
to accounts, so an admin cannot see who rated whom (rule 4). Every view, download and failed
login is in the append-only audit log, without usernames or any personal data (rule 7).
"""

import csv
import io
import secrets
from collections import Counter
from html import escape
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import HTMLResponse, Response
from fastapi.security import HTTPBasic, HTTPBasicCredentials

from app.core import audit
from app.core.config import Settings, get_settings
from app.feedback.export import COLUMNS, rows
from app.identity.router import DbDep

router = APIRouter(prefix="/admin/feedback", include_in_schema=False)

_basic = HTTPBasic(auto_error=False)
_HEADERS = {"Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow"}


def _admin(
    db: DbDep,
    settings: Annotated[Settings, Depends(get_settings)],
    creds: Annotated[HTTPBasicCredentials | None, Depends(_basic)],
) -> None:
    if not settings.admin_password:
        raise HTTPException(status.HTTP_404_NOT_FOUND)
    ok = creds is not None and (
        secrets.compare_digest(creds.username.encode(), settings.admin_username.encode())
        & secrets.compare_digest(creds.password.encode(), settings.admin_password.encode())
    )
    if not ok:
        audit.record(db, "feedback.admin_login_failed")
        db.commit()
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED,
            headers={"WWW-Authenticate": 'Basic realm="SixthSense admin"'},
        )


AdminDep = Annotated[None, Depends(_admin)]


def _avg(values: list[int]) -> str:
    return f"{sum(values) / len(values):.1f}" if values else "–"


def _stars(value: int | str) -> str:
    return "" if value == "" else "★" * int(value) + "☆" * (5 - int(value))


def _page(data: list[dict]) -> str:
    route = [r["route_stars"] for r in data]
    companion = [r["companion_stars"] for r in data if r["companion_stars"] != ""]
    walks = sum(1 for r in data if r["walk_id"])
    chips = Counter(c for r in data for c in r["chips"].split(";") if c)
    chip_html = (
        "".join(f"<li><span>{escape(c)}</span><b>{n}</b></li>" for c, n in chips.most_common())
        or "<li><span>No chips yet</span></li>"
    )
    stats = [
        ("Ratings", str(len(data))),
        ("Journeys", str(len(data) - walks)),
        ("Walks", str(walks)),
        ("Avg route ★", _avg(route)),
        ("Avg companion ★", _avg(companion)),
    ]
    stat_html = "".join(f"<div class=stat><b>{v}</b><span>{k}</span></div>" for k, v in stats)
    body = (
        "".join(
            "<tr>"
            f"<td>{escape(r['created_at'][:16].replace('T', ' '))}</td>"
            f"<td>{'Walk' if r['walk_id'] else 'Journey'}</td>"
            f"<td class=s>{_stars(r['route_stars'])}</td>"
            f"<td class=s>{_stars(r['companion_stars'])}</td>"
            f"<td>{escape(r['chips'].replace(';', ', '))}</td>"
            f"<td class=n>{escape(r['note'])}</td>"
            f"<td class=id title='walk {escape(r['walk_id'])}'>{escape(r['journey_id'])}</td>"
            "</tr>"
            for r in reversed(data)
        )
        or "<tr><td colspan=7 class=empty>No feedback yet.</td></tr>"
    )
    return f"""<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<meta name=robots content="noindex,nofollow"><title>Feedback · SixthSense admin</title>
<style>
:root{{--ink:#2E2658;--lav:#7C55C6;--mist:#F7F0FD;--haze:#DCD1F6;--muted:#6E6790}}
*{{box-sizing:border-box}}body{{margin:0;font:15px/1.45 system-ui,sans-serif;color:var(--ink);
background:var(--mist)}}main{{max-width:1200px;margin:0 auto;padding:24px 16px}}
header{{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap}}
h1{{margin:0;font-size:22px}}p{{color:var(--muted);margin:4px 0 0}}
a.btn{{background:var(--lav);color:#fff;text-decoration:none;padding:10px 16px;
border-radius:10px;font-weight:600}}
.stats{{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px;
margin:20px 0}}.stat{{background:#fff;border:1px solid var(--haze);border-radius:12px;
padding:14px}}.stat b{{display:block;font-size:24px}}.stat span{{color:var(--muted);font-size:13px}}
.card{{background:#fff;border:1px solid var(--haze);border-radius:12px;padding:16px;
margin-bottom:16px}}h2{{font-size:16px;margin:0 0 10px}}
ul{{list-style:none;margin:0;padding:0;display:flex;flex-wrap:wrap;gap:8px}}
li{{background:var(--mist);border-radius:999px;padding:4px 12px}}li b{{margin-left:8px}}
.wrap{{overflow-x:auto}}table{{border-collapse:collapse;width:100%;min-width:900px}}
th,td{{text-align:left;padding:8px 10px;border-bottom:1px solid var(--haze);vertical-align:top}}
th{{font-size:13px;color:var(--muted)}}.s{{color:var(--lav);white-space:nowrap}}
.n{{max-width:340px;white-space:pre-wrap}}.id{{font:12px ui-monospace,monospace;color:var(--muted)}}
.empty{{text-align:center;color:var(--muted);padding:24px}}
</style></head><body><main>
<header><div><h1>Feedback</h1><p>Every "How was it?" rating. Ids only: no names, no
locations. Refresh to see new feedback.</p></div>
<a class=btn href="/admin/feedback/export.csv">Download CSV</a></header>
<div class=stats>{stat_html}</div>
<div class=card><h2>Chips</h2><ul>{chip_html}</ul></div>
<div class="card wrap"><table><thead><tr><th>When (UTC)</th><th>Type</th><th>Route</th>
<th>Companion</th><th>Chips</th><th>Note</th><th>Journey id</th></tr></thead>
<tbody>{body}</tbody></table></div>
</main></body></html>"""


@router.get("", response_class=HTMLResponse)
def feedback_page(_: AdminDep, db: DbDep) -> HTMLResponse:
    data = rows(db)
    audit.record(db, "feedback.admin_view", target=f"rows:{len(data)}")
    db.commit()
    return HTMLResponse(_page(data), headers=_HEADERS)


@router.get("/export.csv")
def feedback_csv(_: AdminDep, db: DbDep) -> Response:
    data = rows(db)
    audit.record(db, "feedback.admin_export", target=f"rows:{len(data)}")
    db.commit()
    out = io.StringIO()
    writer = csv.DictWriter(out, fieldnames=COLUMNS)
    writer.writeheader()
    writer.writerows(data)
    return Response(
        out.getvalue(),
        media_type="text/csv; charset=utf-8",
        headers={**_HEADERS, "Content-Disposition": 'attachment; filename="feedback.csv"'},
    )
