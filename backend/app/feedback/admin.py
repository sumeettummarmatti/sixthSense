"""Admin feedback page (P2-W3-feedback-admin-page, P2-W4-helper-ban).

Every rating in one page plus CSV downloads, and the moderation queue: helpers suspended by a
1-star rating wait here for Ban or Restore, and any companion/responder rating can be turned
into a ban.

Behind HTTP Basic auth (ADMIN_USERNAME / ADMIN_PASSWORD); off (404) while no password is set.
Shows ids, stars, chips and notes only. It never shows who a helper is: the admin acts on the
rating or the case, and the server finds the person (rule 4). Ban/Restore forms carry a CSRF
token. Every view, download, decision and failed login is audited without personal data
(rule 7).
"""

import csv
import hashlib
import hmac
import io
import secrets
import uuid
from collections import Counter
from datetime import UTC, datetime
from html import escape
from typing import Annotated

from fastapi import APIRouter, Depends, Form, HTTPException, status
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from sqlalchemy import select

from app.core import audit
from app.core.config import Settings, get_settings
from app.feedback.export import COLUMNS, rows
from app.feedback.models import Feedback
from app.identity.router import DbDep, RedisDep
from app.matching.models import ResponderOffer
from app.moderation import service as moderation
from app.moderation.models import ModerationCase, ResponderRating
from app.walks.models import Walk

router = APIRouter(prefix="/admin/feedback", include_in_schema=False)

_basic = HTTPBasic(auto_error=False)
_HEADERS = {"Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow"}
SettingsDep = Annotated[Settings, Depends(get_settings)]
RESPONDER_COLUMNS = ("id", "journey_id", "stars", "note", "created_at")


def _admin(
    db: DbDep,
    settings: SettingsDep,
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


def _csrf(settings: Settings) -> str:
    return hmac.new(settings.admin_password.encode(), b"admin-csrf-v1", hashlib.sha256).hexdigest()


def _check_csrf(settings: Settings, token: str) -> None:
    if not secrets.compare_digest(token.encode(), _csrf(settings).encode()):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "bad_csrf_token")


def _now() -> datetime:
    return datetime.now(UTC)


def _avg(values: list[int]) -> str:
    return f"{sum(values) / len(values):.1f}" if values else "–"


def _stars(value: int | str | None) -> str:
    return "" if value in ("", None) else "★" * int(value) + "☆" * (5 - int(value))


def _when(value: str | datetime) -> str:
    text = value.isoformat() if isinstance(value, datetime) else value
    return escape(text[:16].replace("T", " "))


def _button(action: str, label: str, csrf: str, source: str = "", danger: bool = False) -> str:
    confirm = f"return confirm('{label}? This takes effect immediately.')"
    hidden = f"<input type=hidden name=source value='{escape(source)}'>" if source else ""
    return (
        f"<form method=post action='{escape(action)}' onsubmit=\"{confirm}\">"
        f"<input type=hidden name=csrf value='{csrf}'>{hidden}"
        f"<button class='{'danger' if danger else 'ghost'}'>{escape(label)}</button></form>"
    )


def _responder_rows(db) -> list[dict]:
    items = db.scalars(select(ResponderRating).order_by(ResponderRating.created_at)).all()
    return [
        {
            "id": str(r.id),
            "journey_id": str(r.journey_id),
            "stars": r.stars,
            "note": r.note,
            "created_at": r.created_at.isoformat(),
        }
        for r in items
    ]


def _cases(db) -> list[ModerationCase]:
    return list(db.scalars(select(ModerationCase).order_by(ModerationCase.opened_at.desc())))


def _review_note(db, source: str) -> str:
    kind, _, raw = source.partition(":")
    try:
        item_id = uuid.UUID(raw)
    except ValueError:
        return ""
    model = (
        Feedback if kind == "feedback" else ResponderRating if kind == "responder_rating" else None
    )
    item = db.get(model, item_id) if model else None
    return item.note if item is not None else ""


def _page(
    data: list[dict],
    responders: list[dict],
    cases: list[ModerationCase],
    notes: dict[uuid.UUID, str],
    csrf: str,
) -> str:
    route = [r["route_stars"] for r in data]
    companion = [r["companion_stars"] for r in data if r["companion_stars"] != ""]
    walks = sum(1 for r in data if r["walk_id"])
    open_cases = [c for c in cases if c.status == "suspended"]
    banned_sources = {c.source for c in cases if c.status == "banned"}
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
        ("Responder ratings", str(len(responders))),
        ("Avg responder ★", _avg([r["stars"] for r in responders])),
        ("Waiting for you", str(len(open_cases))),
    ]
    stat_html = "".join(f"<div class=stat><b>{v}</b><span>{k}</span></div>" for k, v in stats)

    def ban_cell(source: str, role: str) -> str:
        if source in banned_sources:
            return "<span class=tag>Banned</span>"
        return _button("/admin/feedback/ban", f"Ban {role}", csrf, source, danger=True)

    queue = (
        "".join(
            "<tr>"
            f"<td>{_when(c.opened_at)}</td><td>{escape(c.role.title())}</td>"
            f"<td class=s>{_stars(c.stars)}</td>"
            f"<td class=n>{escape(notes.get(c.id, ''))}</td>"
            f"<td class=id>{str(c.id)[:8]}</td>"
            "<td class=act>"
            f"{_button(f'/admin/feedback/cases/{c.id}/ban', 'Ban', csrf, danger=True)}"
            f"{_button(f'/admin/feedback/cases/{c.id}/restore', 'Restore', csrf)}</td>"
            "</tr>"
            for c in open_cases
        )
        or "<tr><td colspan=6 class=empty>Nobody is waiting for a decision.</td></tr>"
    )
    decided = (
        "".join(
            f"<li><span>{_when(c.decided_at or c.opened_at)} · {escape(c.role)} · "
            f"case {str(c.id)[:8]}</span><b>{escape(c.status)}</b></li>"
            for c in cases
            if c.status != "suspended"
        )
        or "<li><span>No decisions yet</span></li>"
    )
    body = (
        "".join(
            "<tr>"
            f"<td>{_when(r['created_at'])}</td>"
            f"<td>{'Walk' if r['walk_id'] else 'Journey'}</td>"
            f"<td class=s>{_stars(r['route_stars'])}</td>"
            f"<td class=s>{_stars(r['companion_stars'])}</td>"
            f"<td>{escape(r['chips'].replace(';', ', '))}</td>"
            f"<td class=n>{escape(r['note'])}</td>"
            f"<td class=id title='walk {escape(r['walk_id'])}'>{escape(r['journey_id'])}</td>"
            f"<td class=act>{ban_cell('feedback:' + r['id'], 'companion') if r['walk_id'] else ''}"
            "</td></tr>"
            for r in reversed(data)
        )
        or "<tr><td colspan=8 class=empty>No feedback yet.</td></tr>"
    )
    responder_body = (
        "".join(
            "<tr>"
            f"<td>{_when(r['created_at'])}</td>"
            f"<td class=s>{_stars(r['stars'])}</td>"
            f"<td class=n>{escape(r['note'])}</td>"
            f"<td class=id>{escape(r['journey_id'])}</td>"
            f"<td class=act>{ban_cell('responder_rating:' + r['id'], 'responder')}</td>"
            "</tr>"
            for r in reversed(responders)
        )
        or "<tr><td colspan=5 class=empty>No responder ratings yet.</td></tr>"
    )
    return f"""<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<meta name=robots content="noindex,nofollow"><title>Feedback · SixthSense admin</title>
<style>
:root{{--ink:#2E2658;--lav:#7C55C6;--mist:#F7F0FD;--haze:#DCD1F6;--muted:#6E6790;
--sos:#C8364B}}
*{{box-sizing:border-box}}body{{margin:0;font:15px/1.45 system-ui,sans-serif;color:var(--ink);
background:var(--mist)}}main{{max-width:1200px;margin:0 auto;padding:24px 16px}}
header{{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap}}
h1{{margin:0;font-size:22px}}p{{color:var(--muted);margin:4px 0 0}}
a.btn{{background:var(--lav);color:#fff;text-decoration:none;padding:10px 16px;
border-radius:10px;font-weight:600}}.links{{display:flex;gap:8px;flex-wrap:wrap}}
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
.act{{white-space:nowrap}}.act form{{display:inline-block;margin:0 4px 4px 0}}
button{{font:inherit;font-size:13px;border-radius:8px;padding:6px 10px;cursor:pointer}}
button.danger{{background:var(--sos);color:#fff;border:0}}
button.ghost{{background:#fff;color:var(--lav);border:1px solid var(--lav)}}
.tag{{color:var(--sos);font-weight:600;font-size:13px}}
.alert{{border-color:var(--sos)}}
</style></head><body><main>
<header><div><h1>Feedback</h1><p>Every rating. Ids only: no names, no locations. Refresh to
see new feedback.</p></div>
<div class=links><a class=btn href="/admin/feedback/export.csv">Download CSV</a>
<a class=btn href="/admin/feedback/responders.csv">Responder ratings CSV</a></div></header>
<div class=stats>{stat_html}</div>
<div class="card wrap alert"><h2>Waiting for a decision</h2>
<p>A 1★ rating suspends a companion or responder from helping right away. <b>Ban</b> blocks
their account from the app and keeps their face and ID hash so they can't verify again.
<b>Restore</b> lets them help again.</p>
<table><thead><tr><th>When (UTC)</th><th>Role</th><th>Rating</th><th>Review</th><th>Case</th>
<th></th></tr></thead><tbody>{queue}</tbody></table></div>
<div class=card><h2>Chips</h2><ul>{chip_html}</ul></div>
<div class="card wrap"><h2>Journeys and walks</h2><table><thead><tr><th>When (UTC)</th>
<th>Type</th><th>Route</th><th>Companion</th><th>Chips</th><th>Note</th><th>Journey id</th>
<th></th></tr></thead><tbody>{body}</tbody></table></div>
<div class="card wrap"><h2>Responders</h2><table><thead><tr><th>When (UTC)</th><th>Rating</th>
<th>Note</th><th>Journey id</th><th></th></tr></thead><tbody>{responder_body}</tbody></table></div>
<div class=card><h2>Decisions</h2><ul>{decided}</ul></div>
</main></body></html>"""


@router.get("", response_class=HTMLResponse)
def feedback_page(_: AdminDep, db: DbDep, settings: SettingsDep) -> HTMLResponse:
    data = rows(db)
    cases = _cases(db)
    notes = {c.id: _review_note(db, c.source) for c in cases if c.status == "suspended"}
    page = _page(data, _responder_rows(db), cases, notes, _csrf(settings))
    audit.record(db, "feedback.admin_view", target=f"rows:{len(data)}")
    db.commit()
    return HTMLResponse(page, headers=_HEADERS)


def _csv(data: list[dict], columns: tuple[str, ...], name: str) -> Response:
    out = io.StringIO()
    writer = csv.DictWriter(out, fieldnames=columns)
    writer.writeheader()
    writer.writerows(data)
    return Response(
        out.getvalue(),
        media_type="text/csv; charset=utf-8",
        headers={**_HEADERS, "Content-Disposition": f'attachment; filename="{name}"'},
    )


@router.get("/export.csv")
def feedback_csv(_: AdminDep, db: DbDep) -> Response:
    data = rows(db)
    audit.record(db, "feedback.admin_export", target=f"rows:{len(data)}")
    db.commit()
    return _csv(data, COLUMNS, "feedback.csv")


@router.get("/responders.csv")
def responders_csv(_: AdminDep, db: DbDep) -> Response:
    data = _responder_rows(db)
    audit.record(db, "feedback.admin_export_responders", target=f"rows:{len(data)}")
    db.commit()
    return _csv(data, RESPONDER_COLUMNS, "responder-ratings.csv")


def _helper_of(db, source: str) -> tuple[uuid.UUID, moderation.Role, int | None]:
    """Who a rating is about, found on the server (the admin never sees it)."""
    kind, _, raw = source.partition(":")
    try:
        item_id = uuid.UUID(raw)
    except ValueError as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "rating_not_found") from exc
    if kind == "feedback":
        item = db.get(Feedback, item_id)
        walk = db.get(Walk, item.walk_id) if item and item.walk_id else None
        if walk is not None:
            return walk.companion_id, "companion", item.companion_stars
    elif kind == "responder_rating":
        item = db.get(ResponderRating, item_id)
        offer = db.get(ResponderOffer, item.offer_id) if item and item.offer_id else None
        if offer is not None:
            return offer.responder_id, "responder", item.stars
    raise HTTPException(status.HTTP_404_NOT_FOUND, "rating_not_found")


def _back() -> RedirectResponse:
    return RedirectResponse("/admin/feedback", status_code=status.HTTP_303_SEE_OTHER)


@router.post("/ban")
def ban_from_rating(
    _: AdminDep,
    db: DbDep,
    redis: RedisDep,
    settings: SettingsDep,
    csrf: Annotated[str, Form()],
    source: Annotated[str, Form()],
) -> RedirectResponse:
    """Ban the helper a rating is about, whatever the stars."""
    _check_csrf(settings, csrf)
    now = _now()
    case = moderation.case_for_source(db, source)
    if case is None or case.status == "restored":
        account_id, role, stars = _helper_of(db, source)
        case = moderation.open_case(db, account_id, role, source, stars, now)
    if case.status != "banned":
        moderation.ban(db, redis, case, now)
    db.commit()
    return _back()


def _case(db, case_id: uuid.UUID) -> ModerationCase:
    case = db.get(ModerationCase, case_id)
    if case is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "case_not_found")
    return case


@router.post("/cases/{case_id}/ban")
def ban_case(
    case_id: uuid.UUID,
    _: AdminDep,
    db: DbDep,
    redis: RedisDep,
    settings: SettingsDep,
    csrf: Annotated[str, Form()],
) -> RedirectResponse:
    _check_csrf(settings, csrf)
    case = _case(db, case_id)
    if case.status != "banned":
        moderation.ban(db, redis, case, _now())
    db.commit()
    return _back()


@router.post("/cases/{case_id}/restore")
def restore_case(
    case_id: uuid.UUID,
    _: AdminDep,
    db: DbDep,
    settings: SettingsDep,
    csrf: Annotated[str, Form()],
) -> RedirectResponse:
    _check_csrf(settings, csrf)
    case = _case(db, case_id)
    if case.status != "suspended":
        raise HTTPException(status.HTTP_409_CONFLICT, "case_not_suspended")
    moderation.restore(db, case, _now())
    db.commit()
    return _back()
