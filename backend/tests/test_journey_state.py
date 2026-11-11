from datetime import UTC, datetime, timedelta

import pytest

from app.journey.state import (
    Event,
    InvalidTransition,
    JourneyState,
    Outcome,
    State,
    Timers,
    advance_by_time,
    apply_event,
    public_state,
)

T0 = datetime(2026, 11, 11, 20, 0, tzinfo=UTC)
TIMERS = Timers(
    check_in_interval=15,
    check_in_grace=2,
    prompt_timeout=2,
    contact_response=5,
    heartbeat_timeout=30,
)


def minutes(n: float) -> timedelta:
    return timedelta(minutes=n)


def new_journey(state: State = State.ACTIVE) -> JourneyState:
    return JourneyState(
        state=state,
        covert=False,
        next_check_in_at=T0 + minutes(15),
        last_heartbeat_at=T0,
        state_changed_at=T0,
    )


def at(journey: JourneyState, offset: float) -> State:
    advance_by_time(journey, TIMERS, T0 + minutes(offset))
    return journey.state


def test_missed_check_in_escalates_step_by_step() -> None:
    journey = new_journey()
    assert at(journey, 14) == State.ACTIVE
    assert at(journey, 15) == State.CHECK_IN_DUE
    assert at(journey, 17) == State.PRIVATE_PROMPT  # + T1 grace
    assert at(journey, 19) == State.CONTACT_ALERT  # + T2 prompt
    assert at(journey, 23.9) == State.CONTACT_ALERT
    assert at(journey, 24) == State.FULL_ESCALATION  # + contact response


def test_late_watchdog_run_catches_up_with_true_due_times() -> None:
    journey = new_journey()
    assert advance_by_time(journey, TIMERS, T0 + minutes(25))
    assert journey.state == State.FULL_ESCALATION
    assert journey.state_changed_at == T0 + minutes(24)


def test_nothing_due_reports_no_change() -> None:
    assert not advance_by_time(new_journey(), TIMERS, T0 + minutes(1))


def test_heartbeat_lost_alerts_contacts() -> None:
    timers = Timers(60, 2, 2, 5, heartbeat_timeout=5)
    journey = new_journey()
    journey.next_check_in_at = T0 + minutes(60)
    advance_by_time(journey, timers, T0 + minutes(5))
    assert journey.state == State.CONTACT_ALERT


def test_check_in_ok_resets_from_any_open_state() -> None:
    for state in (State.ACTIVE, State.CHECK_IN_DUE, State.PRIVATE_PROMPT, State.CONTACT_ALERT):
        journey = new_journey(state)
        now = T0 + minutes(16)
        apply_event(journey, Event.CHECK_IN_OK, TIMERS, now)
        assert journey.state == State.ACTIVE
        assert journey.next_check_in_at == now + minutes(15)
        assert journey.last_heartbeat_at == now


def test_duress_escalates_silently_and_looks_like_ok() -> None:
    ok, duress = new_journey(State.PRIVATE_PROMPT), new_journey(State.PRIVATE_PROMPT)
    now = T0 + minutes(18)
    apply_event(ok, Event.CHECK_IN_OK, TIMERS, now)
    apply_event(duress, Event.CHECK_IN_DURESS, TIMERS, now)
    assert duress.state == State.FULL_ESCALATION and duress.covert
    assert public_state(duress) == public_state(ok) == State.ACTIVE
    assert duress.next_check_in_at == ok.next_check_in_at


def test_real_pin_after_duress_does_not_cancel_the_alarm() -> None:
    journey = new_journey()
    apply_event(journey, Event.CHECK_IN_DURESS, TIMERS, T0 + minutes(1))
    apply_event(journey, Event.CHECK_IN_OK, TIMERS, T0 + minutes(2))
    assert journey.state == State.FULL_ESCALATION
    assert public_state(journey) == State.ACTIVE


def test_sos_and_covert_sos() -> None:
    loud, quiet = new_journey(), new_journey()
    apply_event(loud, Event.SOS, TIMERS, T0)
    apply_event(quiet, Event.COVERT_SOS, TIMERS, T0)
    assert loud.state == quiet.state == State.FULL_ESCALATION
    assert public_state(loud) == State.FULL_ESCALATION
    assert public_state(quiet) == State.ACTIVE


def test_repeated_sos_is_idempotent() -> None:
    journey = new_journey()
    apply_event(journey, Event.SOS, TIMERS, T0)
    first_change = journey.state_changed_at
    apply_event(journey, Event.SOS, TIMERS, T0 + minutes(1))
    assert journey.state == State.FULL_ESCALATION
    assert journey.state_changed_at == first_change


def test_prompt_shown_moves_to_private_prompt_and_restarts_its_window() -> None:
    journey = new_journey()
    apply_event(journey, Event.PROMPT_SHOWN, TIMERS, T0 + minutes(20))
    assert journey.state == State.PRIVATE_PROMPT
    assert at(journey, 21.9) == State.PRIVATE_PROMPT
    assert at(journey, 22) == State.CONTACT_ALERT


def test_prompt_shown_rejected_during_alert() -> None:
    journey = new_journey(State.CONTACT_ALERT)
    with pytest.raises(InvalidTransition):
        apply_event(journey, Event.PROMPT_SHOWN, TIMERS, T0)


@pytest.mark.parametrize(
    ("event", "outcome"), [(Event.ARRIVE, Outcome.ARRIVED), (Event.END, Outcome.ENDED)]
)
def test_arrive_and_end_resolve(event, outcome) -> None:
    journey = new_journey()
    apply_event(journey, event, TIMERS, T0 + minutes(5))
    assert journey.state == State.RESOLVED and journey.outcome == outcome
    assert not advance_by_time(journey, TIMERS, T0 + minutes(500))


@pytest.mark.parametrize("state", [State.CONTACT_ALERT, State.FULL_ESCALATION])
def test_cannot_end_journey_during_an_alert(state) -> None:
    with pytest.raises(InvalidTransition):
        apply_event(new_journey(state), Event.END, TIMERS, T0)


def test_covert_escalation_looks_resolved_but_keeps_going() -> None:
    journey = new_journey()
    apply_event(journey, Event.CHECK_IN_DURESS, TIMERS, T0)
    apply_event(journey, Event.ARRIVE, TIMERS, T0 + minutes(1))
    assert public_state(journey) == State.RESOLVED
    assert journey.outcome == Outcome.ARRIVED
    assert journey.state == State.FULL_ESCALATION
    with pytest.raises(InvalidTransition):  # same as any finished journey
        apply_event(journey, Event.CHECK_IN_OK, TIMERS, T0 + minutes(2))


def test_no_events_after_resolved() -> None:
    journey = new_journey(State.RESOLVED)
    with pytest.raises(InvalidTransition):
        apply_event(journey, Event.CHECK_IN_OK, TIMERS, T0)


def test_contact_confirms_safe_during_contact_alert_returns_to_active() -> None:
    journey = new_journey(State.CONTACT_ALERT)
    now = T0 + minutes(20)
    apply_event(journey, Event.CONTACT_CONFIRMED_SAFE, TIMERS, now)
    assert journey.state == State.ACTIVE
    assert journey.next_check_in_at == now + minutes(15)
    assert journey.last_heartbeat_at == now


def test_contact_resolves_full_escalation_even_after_covert_fake_end() -> None:
    journey = new_journey()
    apply_event(journey, Event.CHECK_IN_DURESS, TIMERS, T0)
    apply_event(journey, Event.END, TIMERS, T0 + minutes(1))
    apply_event(journey, Event.CONTACT_CONFIRMED_SAFE, TIMERS, T0 + minutes(5))
    assert journey.state == State.RESOLVED
    assert journey.outcome == Outcome.RESOLVED_BY_CONTACT


def test_contact_cannot_resolve_when_no_alert() -> None:
    with pytest.raises(InvalidTransition):
        apply_event(new_journey(), Event.CONTACT_CONFIRMED_SAFE, TIMERS, T0)


def test_acknowledged_contact_alert_does_not_upgrade_by_itself() -> None:
    journey = new_journey(State.CONTACT_ALERT)
    journey.alert_acknowledged_at = T0
    assert not advance_by_time(journey, TIMERS, T0 + minutes(60))
    apply_event(journey, Event.CONTACT_RAISED_ALARM, TIMERS, T0 + minutes(61))
    assert journey.state == State.FULL_ESCALATION
    assert journey.alert_acknowledged_at is None


def test_raise_alarm_needs_an_alert() -> None:
    with pytest.raises(InvalidTransition):
        apply_event(new_journey(), Event.CONTACT_RAISED_ALARM, TIMERS, T0)
