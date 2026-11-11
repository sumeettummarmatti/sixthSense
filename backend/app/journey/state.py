"""Journey state machine (HLD §5.1), as pure functions.

The phone runs the real timers (ADR-2). The server applies the same rules as a watchdog:
phone events go through `apply_event`, and `advance_by_time` moves a journey on when the
phone has gone quiet (called by the W4 watchdog job). Nothing here stores location.

    active          --check-in time-->         check_in_due
    check_in_due    --grace T1 passes-->       private_prompt
    private_prompt  --prompt T2 passes-->      contact_alert
    contact_alert   --no answer-->             full_escalation  (paused once a contact acks)
    contact_alert   --contact raises alarm-->  full_escalation
    open states     --heartbeat lost-->        contact_alert
    any state       --SOS / duress PIN-->      full_escalation
    open states     --real PIN-->              active    (also from contact_alert)
    open states     --arrive / end-->          resolved
    contact_alert   --contact confirms safe--> active
    full_escalation --contact confirms safe--> resolved
    (open states = active, check_in_due, private_prompt)

A duress PIN or covert SOS sets `covert`: the journey escalates, but the owner's phone keeps
being told "active" (see `public_state`), so whoever is holding it sees nothing change. If the
phone then taps "arrive" or "end", it is shown "resolved" while the escalation carries on.
"""

from dataclasses import dataclass
from datetime import datetime, timedelta
from enum import StrEnum


class State(StrEnum):
    ACTIVE = "active"
    CHECK_IN_DUE = "check_in_due"
    PRIVATE_PROMPT = "private_prompt"
    CONTACT_ALERT = "contact_alert"
    FULL_ESCALATION = "full_escalation"
    RESOLVED = "resolved"


class Event(StrEnum):
    CHECK_IN_OK = "check_in_ok"
    CHECK_IN_DURESS = "check_in_duress"
    PROMPT_SHOWN = "prompt_shown"  # phone missed the check-in and is showing the PIN prompt
    SOS = "sos"
    COVERT_SOS = "covert_sos"
    ARRIVE = "arrive"
    END = "end"
    CONTACT_CONFIRMED_SAFE = "contact_confirmed_safe"  # a trusted contact resolved the alert
    CONTACT_RAISED_ALARM = "contact_raised_alarm"  # a contact couldn't reach them


class Outcome(StrEnum):
    ARRIVED = "arrived"
    ENDED = "ended"
    RESOLVED_BY_CONTACT = "resolved_by_contact"


OPEN_STATES = frozenset({State.ACTIVE, State.CHECK_IN_DUE, State.PRIVATE_PROMPT})
ESCALATED_STATES = frozenset({State.CONTACT_ALERT, State.FULL_ESCALATION})


@dataclass(frozen=True)
class Timers:
    """Minutes, copied from the owner's protocol when the journey starts."""

    check_in_interval: int
    check_in_grace: int  # T1: due → private prompt
    prompt_timeout: int  # T2: private prompt → contact alert
    contact_response: int  # contact alert → full escalation
    heartbeat_timeout: int


@dataclass
class JourneyState:
    state: State
    covert: bool
    next_check_in_at: datetime
    last_heartbeat_at: datetime
    state_changed_at: datetime
    outcome: Outcome | None = None  # for a covert journey: what the phone was shown
    cover_ended_at: datetime | None = None  # covert journey the phone believes is over
    alert_acknowledged_at: datetime | None = None  # a contact said "I'm on it" (contact_alert)


class InvalidTransition(ValueError):
    pass


def _set(journey: JourneyState, state: State, now: datetime) -> None:
    journey.state = state
    journey.state_changed_at = now
    if state != State.CONTACT_ALERT:
        journey.alert_acknowledged_at = None


def apply_event(journey: JourneyState, event: Event, timers: Timers, now: datetime) -> None:
    """Apply a phone event in place. Raises InvalidTransition if it makes no sense now."""
    interval = timedelta(minutes=timers.check_in_interval)

    if event == Event.CONTACT_CONFIRMED_SAFE:
        # From a contact, not the phone, so a covert journey the phone thinks is over still counts.
        if journey.state == State.CONTACT_ALERT:
            journey.next_check_in_at = now + interval
            journey.last_heartbeat_at = now  # fresh window before the watchdog looks again
            _set(journey, State.ACTIVE, now)
        elif journey.state == State.FULL_ESCALATION:
            journey.outcome = Outcome.RESOLVED_BY_CONTACT
            _set(journey, State.RESOLVED, now)
        else:
            raise InvalidTransition("no alert to resolve")
        return

    if event == Event.CONTACT_RAISED_ALARM:
        if journey.state == State.CONTACT_ALERT:
            _set(journey, State.FULL_ESCALATION, now)
        elif journey.state != State.FULL_ESCALATION:
            raise InvalidTransition("no alert to raise")
        return

    if journey.state == State.RESOLVED or journey.cover_ended_at is not None:
        raise InvalidTransition("journey is over")
    journey.last_heartbeat_at = now

    if event in (Event.CHECK_IN_OK, Event.CHECK_IN_DURESS):
        # Both PINs move the visible deadline the same way, so the phone shows the same thing.
        journey.next_check_in_at = now + interval
        if event == Event.CHECK_IN_DURESS:
            if journey.state != State.FULL_ESCALATION:
                _set(journey, State.FULL_ESCALATION, now)
            journey.covert = True
        elif journey.state in OPEN_STATES or journey.state == State.CONTACT_ALERT:
            _set(journey, State.ACTIVE, now)
        # A real PIN never cancels a full escalation: only contacts/responders resolve it (W4).
        return

    if event == Event.PROMPT_SHOWN:
        if journey.state in (State.ACTIVE, State.CHECK_IN_DUE):
            _set(journey, State.PRIVATE_PROMPT, now)
        elif journey.state != State.PRIVATE_PROMPT:
            raise InvalidTransition("no check-in is pending")
        return

    if event in (Event.SOS, Event.COVERT_SOS):
        if journey.state != State.FULL_ESCALATION:
            _set(journey, State.FULL_ESCALATION, now)
        if event == Event.COVERT_SOS:
            journey.covert = True
        return

    if event in (Event.ARRIVE, Event.END):
        if journey.covert and journey.state == State.FULL_ESCALATION:
            # Look finished to whoever holds the phone; the escalation keeps going.
            journey.outcome = Outcome.ARRIVED if event == Event.ARRIVE else Outcome.ENDED
            journey.cover_ended_at = now
            return
        if journey.state not in OPEN_STATES:
            raise InvalidTransition("an alert is in progress")
        journey.outcome = Outcome.ARRIVED if event == Event.ARRIVE else Outcome.ENDED
        _set(journey, State.RESOLVED, now)
        return

    raise InvalidTransition(f"unknown event {event}")  # pragma: no cover


def advance_by_time(journey: JourneyState, timers: Timers, now: datetime) -> bool:
    """Watchdog step: apply every timer transition that is due. Returns True if anything moved."""
    moved = False
    while (step := _next_timed_step(journey, timers)) is not None and step[1] <= now:
        # Stamp each step with when it was due, not when the watchdog ran, so a late run
        # doesn't push later deadlines back.
        _set(journey, *step)
        moved = True
    return moved


def _next_timed_step(journey: JourneyState, timers: Timers) -> tuple[State, datetime] | None:
    """The next timer transition for this journey and when it is due."""
    minutes = lambda n: timedelta(minutes=n)  # noqa: E731
    state, due = journey.state, journey.next_check_in_at
    candidates: list[tuple[State, datetime]] = []
    if state in OPEN_STATES:
        lost_at = journey.last_heartbeat_at + minutes(timers.heartbeat_timeout)
        candidates.append((State.CONTACT_ALERT, lost_at))
    if state == State.ACTIVE:
        candidates.append((State.CHECK_IN_DUE, due))
    elif state == State.CHECK_IN_DUE:
        candidates.append((State.PRIVATE_PROMPT, due + minutes(timers.check_in_grace)))
    elif state == State.PRIVATE_PROMPT:
        prompt_started = max(due + minutes(timers.check_in_grace), journey.state_changed_at)
        candidates.append((State.CONTACT_ALERT, prompt_started + minutes(timers.prompt_timeout)))
    elif state == State.CONTACT_ALERT and journey.alert_acknowledged_at is None:
        # Someone said "I'm on it": they resolve it or raise the alarm; the timer waits.
        at = journey.state_changed_at + minutes(timers.contact_response)
        candidates.append((State.FULL_ESCALATION, at))
    return min(candidates, key=lambda step: step[1], default=None)


def public_state(journey: JourneyState) -> State:
    """What the owner's phone is told. A covert escalation keeps looking like a normal journey."""
    if journey.covert and journey.state == State.FULL_ESCALATION:
        return State.RESOLVED if journey.cover_ended_at else State.ACTIVE
    return journey.state
