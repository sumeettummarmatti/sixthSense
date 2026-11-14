"""Contact side of an alert (P2-W4): see open alerts, say "I'm on it", confirm they're safe.

A contact sees an alert only while it is open and only if they are one of its recipients
(rule 4). Acknowledging stops the ladder; it does not end the alert. Confirming safe does.
"""

import uuid
from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import HTMLResponse
from sqlalchemy import select

from app.core import audit
from app.core.redis import get_redis
from app.escalation import helpers, ladder, schemas
from app.escalation.models import Escalation, EscalationRecipient
from app.identity.router import CurrentSessionDep, DbDep, SettingsDep
from app.journey.models import Journey
from app.journey.state import ESCALATED_STATES, Event, InvalidTransition, State, apply_event
from app.matching import nearby
from app.notification import signing
from app.notification.channels import Senders, get_senders

router = APIRouter(prefix="/escalations", tags=["escalation"])

_NOT_FOUND = HTTPException(status.HTTP_404_NOT_FOUND, "escalation_not_found")
SendersDep = Annotated[Senders, Depends(get_senders)]
RedisDep = Annotated[object, Depends(get_redis)]


def _now() -> datetime:
    return datetime.now(UTC)


NowDep = Annotated[datetime, Depends(_now)]


def _open_for_recipient(
    db: DbDep, escalation_id: uuid.UUID, contact_id: uuid.UUID
) -> tuple[Escalation, EscalationRecipient]:
    row = db.execute(
        select(Escalation, EscalationRecipient)
        .join(EscalationRecipient, EscalationRecipient.escalation_id == Escalation.id)
        .where(
            Escalation.id == escalation_id,
            Escalation.closed_at.is_(None),
            EscalationRecipient.contact_account_id == contact_id,
        )
        .with_for_update(of=Escalation)
    ).first()
    if row is None:
        raise _NOT_FOUND
    return row[0], row[1]


def _contacts_only(recipient: EscalationRecipient) -> None:
    """A walk companion (a verified stranger) can never close or change someone's alarm."""
    if recipient.kind != "contact":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "contacts_only")


@router.get("/active", response_model=schemas.ActiveEscalations)
def active(
    session: CurrentSessionDep, db: DbDep, settings: SettingsDep
) -> schemas.ActiveEscalations:
    rows = db.execute(
        select(Escalation, EscalationRecipient)
        .join(EscalationRecipient, EscalationRecipient.escalation_id == Escalation.id)
        .where(
            Escalation.closed_at.is_(None),
            EscalationRecipient.contact_account_id == session.account_id,
        )
        .order_by(Escalation.opened_at)
    ).all()
    return schemas.ActiveEscalations(
        escalations=[
            schemas.ActiveEscalation(
                id=escalation.id,
                journey_id=escalation.journey_id,
                owner_label=recipient.owner_label,
                level=escalation.level,
                covert=escalation.covert,
                opened_at=escalation.opened_at,
                acknowledged=escalation.acknowledged_at is not None,
                i_am_helping=helpers.is_helping(db, escalation.id, session.account_id),
                helpers_going=helpers.count_going(db, escalation.id),
                verification_code=signing.verification_code(
                    settings.token_secret, str(escalation.id), str(session.account_id)
                ),
            )
            for escalation, recipient in rows
        ]
    )


@router.post("/{escalation_id}/ack", response_model=schemas.Acknowledged)
def acknowledge(
    escalation_id: uuid.UUID, session: CurrentSessionDep, db: DbDep, now: NowDep
) -> schemas.Acknowledged:
    """'I'm on it.' Stops further alerts to everyone; the alert stays open until resolved.
    A walk companion's "I'm on it" shows them as coming but keeps alerting the contacts."""
    escalation, recipient = _open_for_recipient(db, escalation_id, session.account_id)
    ladder.acknowledge(db, escalation, session.account_id, now, kind=recipient.kind)
    db.commit()
    return schemas.Acknowledged(owner_label=recipient.owner_label)


@router.get("/{escalation_id}/owner-keys", response_model=schemas.OwnerKeys)
def owner_keys(
    escalation_id: uuid.UUID, session: CurrentSessionDep, db: DbDep
) -> schemas.OwnerKeys:
    """For a contact who said "I'm on it": the traveller's keys, to share their own location
    back so the traveller sees them coming. Only while the alert is open."""
    escalation, _ = _open_for_recipient(db, escalation_id, session.account_id)
    if escalation.journey_id is None or not helpers.is_helping(
        db, escalation.id, session.account_id
    ):
        raise _NOT_FOUND
    return schemas.OwnerKeys(
        journey_id=escalation.journey_id, keys=helpers.device_keys(db, escalation.owner_id)
    )


def _owned_open_journey(db: DbDep, account_id: uuid.UUID, journey_id: uuid.UUID) -> Journey:
    journey = db.get(Journey, journey_id)
    if journey is None or journey.account_id != account_id or journey.state == State.RESOLVED:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no_open_journey")
    return journey


@router.get("/help/{journey_id}", response_model=schemas.HelpView)
def help_view(
    journey_id: uuid.UUID,
    session: CurrentSessionDep,
    db: DbDep,
    redis: RedisDep,
    settings: SettingsDep,
    now: NowDep,
) -> schemas.HelpView:
    """The traveller's view: is an alert open, and who said they are coming."""
    journey = _owned_open_journey(db, session.account_id, journey_id)
    search = None
    full = db.scalars(
        select(Escalation).where(
            Escalation.journey_id == journey.id,
            Escalation.closed_at.is_(None),
            Escalation.level == State.FULL_ESCALATION.value,
        )
    ).first()
    if full is not None:
        found = nearby.search_summary(db, redis, settings, full, now)
        search = schemas.ResponderSearch(
            radius_m=found.radius_m,
            on_duty_nearby=found.on_duty_nearby,
            asked=found.asked,
            going=found.going,
        )
    return schemas.HelpView(
        full_alert=journey.state == State.FULL_ESCALATION,
        any_alert=journey.state in {s.value for s in ESCALATED_STATES},
        helpers=helpers.for_owner(db, session.account_id, journey.id),
        search=search,
    )


@router.put("/area/{journey_id}", status_code=status.HTTP_204_NO_CONTENT)
def put_area(
    journey_id: uuid.UUID,
    body: schemas.AlertArea,
    session: CurrentSessionDep,
    db: DbDep,
    redis: RedisDep,
    settings: SettingsDep,
) -> None:
    """Rough area during a full alert so nearby responders can be asked. Ignored otherwise."""
    journey = _owned_open_journey(db, session.account_id, journey_id)
    if journey.state != State.FULL_ESCALATION:
        raise HTTPException(status.HTTP_409_CONFLICT, "no_full_alert")
    nearby.set_alert_area(redis, journey.id, nearby.rough(body.latitude, body.longitude), settings)


@router.post("/{escalation_id}/resolve", response_model=schemas.Resolved)
def resolve(
    escalation_id: uuid.UUID,
    session: CurrentSessionDep,
    db: DbDep,
    senders: SendersDep,
    now: NowDep,
) -> schemas.Resolved:
    """'They're safe.' A missed check-in goes back to normal; a full alert ends the journey."""
    escalation, recipient = _open_for_recipient(db, escalation_id, session.account_id)
    _contacts_only(recipient)
    journey = db.get(Journey, escalation.journey_id, with_for_update=True)
    closed = []
    if journey is not None:
        current = journey.to_state()
        try:
            apply_event(current, Event.CONTACT_CONFIRMED_SAFE, journey.timers(), now)
        except InvalidTransition as exc:
            raise HTTPException(status.HTTP_409_CONFLICT, "nothing_to_resolve") from exc
        journey.load_state(current)
        audit.record(
            db,
            "journey.contact_confirmed_safe",
            actor=session.account_id,
            target=f"journey:{journey.id}",
        )
        others = db.scalars(
            select(Escalation).where(
                Escalation.journey_id == journey.id, Escalation.closed_at.is_(None)
            )
        )
        closed = [
            ladder.close(db, other, "resolved_by_contact", now, resolved_by=session.account_id)
            for other in others
        ]
    else:
        closed = [
            ladder.close(db, escalation, "resolved_by_contact", now, resolved_by=session.account_id)
        ]
    ladder.acknowledge(db, escalation, session.account_id, now)
    db.commit()
    ladder.send_all_clear(db, senders, closed)
    state = journey.state if journey is not None else State.RESOLVED.value
    return schemas.Resolved(journey_state=state)


@router.post("/{escalation_id}/raise", response_model=schemas.Raised)
def raise_alarm(
    escalation_id: uuid.UUID, session: CurrentSessionDep, db: DbDep, now: NowDep
) -> schemas.Raised:
    """'I can't reach them.' Turns a missed check-in into a full escalation for everyone."""
    escalation, recipient = _open_for_recipient(db, escalation_id, session.account_id)
    _contacts_only(recipient)
    journey = db.get(Journey, escalation.journey_id, with_for_update=True)
    if journey is None:
        raise _NOT_FOUND
    current = journey.to_state()
    try:
        apply_event(current, Event.CONTACT_RAISED_ALARM, journey.timers(), now)
    except InvalidTransition as exc:
        raise HTTPException(status.HTTP_409_CONFLICT, "nothing_to_raise") from exc
    journey.load_state(current)
    audit.record(
        db, "journey.contact_raised_alarm", actor=session.account_id, target=f"journey:{journey.id}"
    )
    db.commit()
    return schemas.Raised()


@router.post("/ack", response_model=schemas.Acknowledged)
def acknowledge_by_link(
    body: schemas.LinkAck, settings: SettingsDep, db: DbDep, now: NowDep
) -> schemas.Acknowledged:
    """'I'm on it' from the link in a Telegram message or email (no sign-in needed)."""
    row = db.execute(
        select(Escalation, EscalationRecipient)
        .join(EscalationRecipient, EscalationRecipient.escalation_id == Escalation.id)
        .where(
            EscalationRecipient.ack_token_hash == ladder.ack_token_hash(settings, body.token),
            Escalation.closed_at.is_(None),
        )
        .with_for_update(of=Escalation)
    ).first()
    if row is None:
        raise _NOT_FOUND
    escalation, recipient = row
    ladder.acknowledge(db, escalation, recipient.contact_account_id, now, kind=recipient.kind)
    db.commit()
    return schemas.Acknowledged(owner_label=recipient.owner_label)


_ACK_PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SixthSense alert</title>
<style>
body{font-family:system-ui,sans-serif;margin:0;padding:24px;background:#f6f3fb;color:#241d33}
main{max-width:420px;margin:auto}button{font-size:18px;padding:14px 20px;border:0;
border-radius:12px;background:#5b4b8a;color:#fff;width:100%}p{line-height:1.5}
</style></head><body><main>
<h1>SixthSense alert</h1>
<p id="msg">Tap below to tell the others you're handling this alert.</p>
<button id="ack">I'm on it</button>
<p>If you think someone is in danger, call <a href="tel:112">112</a>.</p>
</main><script>
const token = location.hash.slice(1);
document.getElementById("ack").onclick = async () => {
  const r = await fetch("ack", {method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({token})});
  document.getElementById("msg").textContent = r.ok
    ? "Thanks. Others know you're on it. Open SixthSense for details."
    : "This alert has ended or the link is no longer valid.";
  document.getElementById("ack").remove();
};
</script></body></html>"""


@router.get("/ack", response_class=HTMLResponse, include_in_schema=False)
def acknowledge_page() -> HTMLResponse:
    """Tiny page behind the alert link. The token stays in the '#' part, so link previewers
    and server logs never see it, and nothing happens until the contact taps the button."""
    return HTMLResponse(
        _ACK_PAGE, headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer"}
    )
