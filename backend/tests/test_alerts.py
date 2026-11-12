import base64
import json
import logging
import os
import re
import uuid
from datetime import UTC, datetime, timedelta

import httpx
import pytest
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from sqlalchemy import select, update

from app.core.audit import AuditEvent
from app.core.config import get_settings
from app.escalation import ladder
from app.escalation.models import Escalation, EscalationRecipient
from app.escalation.router import _now as escalation_now
from app.identity.models import Device
from app.journey import service as journeys
from app.journey.models import Journey
from app.journey.router import _now as journey_now
from app.main import app
from app.notification import signing
from app.notification.channels import FcmSender, Message, Senders, TelegramSender, get_senders
from app.notification.models import AlertChannels
from app.notification.router import link_telegram_chats

T0 = datetime(2026, 11, 11, 20, 0, tzinfo=UTC)


class FakeSender:
    def __init__(self, name: str, configured: bool = True) -> None:
        self.name = name
        self._configured = configured
        self.sent: list[tuple[str, Message]] = []
        self.updates: list[dict] = []

    def configured(self) -> bool:
        return self._configured

    def send(self, target: str, message: Message) -> bool:
        self.sent.append((target, message))
        return True

    def get_updates(self, offset: int) -> list[dict]:
        updates, self.updates = self.updates, []
        return updates


class Clock:
    def __init__(self) -> None:
        self.now = T0

    def advance(self, seconds: float) -> datetime:
        self.now += timedelta(seconds=seconds)
        return self.now


@pytest.fixture
def senders(client) -> Senders:
    fakes = Senders(
        push=FakeSender("push"), telegram=FakeSender("telegram"), email=FakeSender("email")
    )
    app.dependency_overrides[get_senders] = lambda: fakes
    return fakes


@pytest.fixture
def clock(client) -> Clock:
    clock = Clock()
    app.dependency_overrides[journey_now] = lambda: clock.now
    app.dependency_overrides[escalation_now] = lambda: clock.now
    return clock


@pytest.fixture
def people(client, make_user, senders):
    """An owner with two accepted contacts: Asha (push) and Ben (Telegram + email)."""
    owner = make_user("owner@college.edu")
    asha = make_user("asha@college.edu")
    ben = make_user("ben@college.edu")
    links = {}
    for name, contact in (("asha", asha), ("ben", ben)):
        invite = client.post(
            "/contacts/invites", json={"owner_label": "Priya"}, headers=owner["headers"]
        ).json()
        client.post(
            "/contacts/invites/accept",
            json={"invite_token": invite["invite_token"]},
            headers=contact["headers"],
        )
        links[name] = invite["contact_link_id"]
    client.put("/notifications/push-token", json={"fcm_token": "asha-fcm"}, headers=asha["headers"])
    client.put("/notifications/email", json={"email": "ben@college.edu"}, headers=ben["headers"])
    return {"owner": owner, "asha": asha, "ben": ben, "links": links}


def link_telegram(client, db, redis, senders, contact, chat_id: int) -> None:
    settings = get_settings().model_copy(update={"telegram_bot_username": "sixthsense_bot"})
    app.dependency_overrides[get_settings] = lambda: settings
    url = client.post("/notifications/telegram/link", headers=contact["headers"]).json()["url"]
    token = url.split("start=")[1]
    senders.telegram.updates = [
        {"update_id": 7, "message": {"text": f"/start {token}", "chat": {"id": chat_id}}}
    ]
    assert link_telegram_chats(db, redis, settings, senders) == 1
    del app.dependency_overrides[get_settings]


def start_journey(client, owner, clock) -> str:
    resp = client.post("/journeys", json={}, headers=owner["headers"])
    assert resp.status_code == 201
    return resp.json()["id"]


def tick(db, senders, clock, seconds: float = 0) -> list:
    now = clock.advance(seconds)
    journeys.run_watchdog(db, now)
    closed = ladder.sync(db, get_settings(), now)
    ladder.send_due(db, senders, get_settings(), now)
    ladder.send_all_clear(db, senders, closed)
    return closed


def silent_until_contact_alert(db, senders, clock) -> None:
    """The phone goes quiet; after 10 minutes the watchdog alerts contacts."""
    tick(db, senders, clock, 10 * 60)


def escalations(db, owner) -> list[Escalation]:
    """This owner's escalations (the dev database may hold others from manual runs)."""
    db.expire_all()
    return list(
        db.scalars(
            select(Escalation)
            .where(Escalation.owner_id == uuid.UUID(owner["account_id"]))
            .order_by(Escalation.opened_at)
        )
    )


def everything_sent(senders) -> list[tuple[str, str, str]]:
    return [
        (channel, target, message.title)
        for channel in ("push", "telegram", "email")
        for target, message in senders.by_name(channel).sent
    ]


# --- alerting ------------------------------------------------------------------------------


def test_missed_check_in_alerts_all_contacts_at_once(client, db, senders, clock, people) -> None:
    start_journey(client, people["owner"], clock)
    silent_until_contact_alert(db, senders, clock)
    [escalation] = escalations(db, people["owner"])
    assert escalation.level == "contact_alert" and not escalation.covert
    # both contacts in the same tick, each on the first channel they have
    assert everything_sent(senders) == [
        ("push", "asha-fcm", "Priya missed a safety check-in"),
        ("email", "ben@college.edu", "Priya missed a safety check-in"),
    ]
    _, message = senders.push.sent[0]
    assert message.ack_url.startswith(f"{get_settings().public_base_url}/escalations/ack#")
    assert "maps" not in message.text().lower()


def test_ladder_moves_down_channels_then_repeats(client, db, redis, senders, clock, people) -> None:
    link_telegram(client, db, redis, senders, people["asha"], chat_id=555)
    senders.telegram.sent.clear()
    start_journey(client, people["owner"], clock)
    silent_until_contact_alert(db, senders, clock)
    assert [t for t, _ in senders.push.sent] == ["asha-fcm"]
    tick(db, senders, clock, 59)
    assert senders.telegram.sent == []  # not yet a minute
    tick(db, senders, clock, 1)
    assert [t for t, _ in senders.telegram.sent] == ["555"]  # Asha: push -> telegram
    tick(db, senders, clock, 60)
    assert [t for t, _ in senders.email.sent] == ["ben@college.edu"]  # Ben has only email
    pushes = len(senders.push.sent)
    tick(db, senders, clock, 300)
    assert len(senders.push.sent) == pushes + 1  # ladder starts over after 5 minutes


def test_acknowledge_stops_alerts_for_everyone(client, db, senders, clock, people) -> None:
    start_journey(client, people["owner"], clock)
    silent_until_contact_alert(db, senders, clock)
    [escalation] = escalations(db, people["owner"])
    resp = client.post(f"/escalations/{escalation.id}/ack", headers=people["ben"]["headers"])
    assert resp.status_code == 200 and resp.json()["owner_label"] == "Priya"
    sent = len(everything_sent(senders))
    tick(db, senders, clock, 3600)
    assert len(everything_sent(senders)) == sent  # no more ladder, and no automatic upgrade
    assert [e.level for e in escalations(db, people["owner"])] == ["contact_alert"]
    active = client.get("/escalations/active", headers=people["asha"]["headers"]).json()
    assert active["escalations"][0]["acknowledged"] is True


def test_acknowledge_by_link_without_sign_in(client, db, senders, clock, people) -> None:
    start_journey(client, people["owner"], clock)
    silent_until_contact_alert(db, senders, clock)
    token = senders.push.sent[0][1].ack_url.split("#")[1]
    assert client.get("/escalations/ack").status_code == 200  # the tap-to-confirm page
    resp = client.post("/escalations/ack", json={"token": token})
    assert resp.status_code == 200
    assert escalations(db, people["owner"])[0].acknowledged_by == uuid.UUID(
        people["asha"]["account_id"]
    )
    assert client.post("/escalations/ack", json={"token": "wrong"}).status_code == 404


def test_contact_can_raise_the_alarm(client, db, senders, clock, people) -> None:
    start_journey(client, people["owner"], clock)
    silent_until_contact_alert(db, senders, clock)
    [escalation] = escalations(db, people["owner"])
    client.post(f"/escalations/{escalation.id}/ack", headers=people["ben"]["headers"])
    resp = client.post(f"/escalations/{escalation.id}/raise", headers=people["ben"]["headers"])
    assert resp.status_code == 200 and resp.json() == {"journey_state": "full_escalation"}
    tick(db, senders, clock, 1)
    first, second = escalations(db, people["owner"])
    assert first.close_reason == "superseded" and second.level == "full_escalation"
    assert senders.push.sent[-1][1].title == "URGENT: Priya may need help now"


def test_duplicate_triggers_send_nothing_extra(client, db, senders, clock, people) -> None:
    journey_id = start_journey(client, people["owner"], clock)
    owner = people["owner"]["headers"]
    for _ in range(3):
        client.post(f"/journeys/{journey_id}/sos", json={}, headers=owner)
        tick(db, senders, clock)
    assert len(escalations(db, people["owner"])) == 1
    assert len(everything_sent(senders)) == 2  # one per contact


def test_contact_alert_upgrades_to_full_escalation(client, db, senders, clock, people) -> None:
    start_journey(client, people["owner"], clock)
    silent_until_contact_alert(db, senders, clock)
    tick(db, senders, clock, 5 * 60)  # contacts didn't answer
    first, second = escalations(db, people["owner"])
    assert first.level == "contact_alert" and first.close_reason == "superseded"
    assert second.level == "full_escalation" and second.closed_at is None
    titles = [title for _, _, title in everything_sent(senders)]
    assert "URGENT: Priya may need help now" in titles


def test_duress_sends_silent_alarm_wording(client, db, senders, clock, people) -> None:
    journey_id = start_journey(client, people["owner"], clock)
    resp = client.post(
        f"/journeys/{journey_id}/check-in",
        json={"result": "duress"},
        headers=people["owner"]["headers"],
    )
    assert resp.json()["state"] == "active"
    tick(db, senders, clock)
    _, message = senders.push.sent[0]
    assert message.title == "URGENT: Priya triggered a silent alarm"
    assert "Do NOT call their phone" in message.body
    active = client.get("/escalations/active", headers=people["asha"]["headers"]).json()
    assert active["escalations"][0]["covert"] is True


def test_owner_check_in_closes_alert_and_sends_all_clear(
    client, db, senders, clock, people
) -> None:
    journey_id = start_journey(client, people["owner"], clock)
    silent_until_contact_alert(db, senders, clock)
    client.post(
        f"/journeys/{journey_id}/check-in",
        json={"result": "ok"},
        headers=people["owner"]["headers"],
    )
    closed = tick(db, senders, clock, 1)
    assert [c.reason for c in closed] == ["owner_checked_in"]
    assert senders.push.sent[-1][1].body == "Priya checked in and is OK."
    assert senders.email.sent[-1][1].title == "All clear"
    assert client.get("/escalations/active", headers=people["asha"]["headers"]).json() == {
        "escalations": []
    }


def test_same_journey_can_alert_again_after_calming_down(
    client, db, senders, clock, people
) -> None:
    journey_id = start_journey(client, people["owner"], clock)
    silent_until_contact_alert(db, senders, clock)
    client.post(
        f"/journeys/{journey_id}/check-in",
        json={"result": "ok"},
        headers=people["owner"]["headers"],
    )
    tick(db, senders, clock, 1)
    silent_until_contact_alert(db, senders, clock)
    assert [e.level for e in escalations(db, people["owner"])] == ["contact_alert", "contact_alert"]
    assert escalations(db, people["owner"])[1].closed_at is None


def test_contact_confirms_safe_during_missed_check_in(client, db, senders, clock, people) -> None:
    journey_id = start_journey(client, people["owner"], clock)
    silent_until_contact_alert(db, senders, clock)
    [escalation] = escalations(db, people["owner"])
    resp = client.post(f"/escalations/{escalation.id}/resolve", headers=people["asha"]["headers"])
    assert resp.status_code == 200 and resp.json() == {"journey_state": "active"}
    assert escalations(db, people["owner"])[0].close_reason == "resolved_by_contact"
    assert senders.email.sent[-1][1].body == "Another trusted contact confirmed Priya is safe."
    # Asha resolved it, so she gets no "another contact confirmed" message (seen in the demo)
    assert [m.title for _, m in senders.push.sent] == ["Priya missed a safety check-in"]
    db.expire_all()
    assert db.get(Journey, uuid.UUID(journey_id)).state == "active"


def test_contact_resolves_covert_alarm_and_journey_ends(client, db, senders, clock, people) -> None:
    journey_id = start_journey(client, people["owner"], clock)
    client.post(
        f"/journeys/{journey_id}/sos", json={"covert": True}, headers=people["owner"]["headers"]
    )
    tick(db, senders, clock)
    [escalation] = escalations(db, people["owner"])
    resp = client.post(f"/escalations/{escalation.id}/resolve", headers=people["ben"]["headers"])
    assert resp.json() == {"journey_state": "resolved"}
    db.expire_all()
    journey = db.get(Journey, uuid.UUID(journey_id))
    assert journey.state == "resolved" and journey.outcome == "resolved_by_contact"


def test_only_recipients_see_or_act_on_an_alert(
    client, db, senders, clock, people, make_user
) -> None:
    start_journey(client, people["owner"], clock)
    silent_until_contact_alert(db, senders, clock)
    [escalation] = escalations(db, people["owner"])
    stranger = make_user("stranger@college.edu")
    for who in (stranger, people["owner"]):
        assert client.get("/escalations/active", headers=who["headers"]).json() == {
            "escalations": []
        }
        for action in ("ack", "resolve", "raise"):
            resp = client.post(f"/escalations/{escalation.id}/{action}", headers=who["headers"])
            assert resp.status_code == 404


def test_removed_contact_is_not_alerted(client, db, senders, clock, people) -> None:
    owner = people["owner"]["headers"]
    client.delete(f"/contacts/{people['links']['ben']}", headers=owner)
    start_journey(client, people["owner"], clock)
    silent_until_contact_alert(db, senders, clock)
    assert [target for _, target, _ in everything_sent(senders)] == ["asha-fcm"]


def test_protocol_can_limit_who_is_alerted(client, db, senders, clock, people) -> None:
    client.put(
        "/journeys/protocol",
        json={"alert_contact_ids": [people["links"]["asha"]]},
        headers=people["owner"]["headers"],
    )
    start_journey(client, people["owner"], clock)
    silent_until_contact_alert(db, senders, clock)
    assert [target for _, target, _ in everything_sent(senders)] == ["asha-fcm"]


def test_no_contacts_and_unreachable_contacts_are_recorded(
    client, db, senders, clock, make_user
) -> None:
    lonely = make_user("lonely@college.edu")
    start_journey(client, lonely, clock)
    silent_until_contact_alert(db, senders, clock)
    assert "escalation.no_contacts" in set(db.scalars(select(AuditEvent.action)))

    owner, quiet = make_user("owner2@college.edu"), make_user("quiet@college.edu")
    invite = client.post(
        "/contacts/invites", json={"owner_label": "Riya"}, headers=owner["headers"]
    ).json()
    client.post(
        "/contacts/invites/accept",
        json={"invite_token": invite["invite_token"]},
        headers=quiet["headers"],
    )
    start_journey(client, owner, clock)
    silent_until_contact_alert(db, senders, clock)
    assert "escalation.unreachable" in set(db.scalars(select(AuditEvent.action)))
    for _ in range(20):  # keeps trying every 5 minutes (they may set a channel up), then stops
        tick(db, senders, clock, 300)
    db.expire_all()
    # unanswered, so the alert also went to full escalation: every recipient row gave up in the end
    recipients = db.scalars(
        select(EscalationRecipient).where(
            EscalationRecipient.contact_account_id == uuid.UUID(quiet["account_id"])
        )
    ).all()
    full = [r for r in recipients if r.cycle == 12]
    assert full and all(r.next_attempt_at is None for r in full)


# --- channel setup -------------------------------------------------------------------------


def test_channel_setup_and_encryption_at_rest(client, db, senders, people) -> None:
    asha, ben = people["asha"], people["ben"]
    assert client.get("/notifications/channels", headers=asha["headers"]).json() == {
        "push": True,
        "telegram": False,
        "email": False,
        "push_available": True,
        "telegram_available": True,
    }
    assert client.get("/notifications/channels", headers=ben["headers"]).json()["email"] is True
    db.expire_all()
    device = db.get(Device, uuid.UUID(asha["device_id"]))
    assert b"asha-fcm" not in device.fcm_token_enc
    channels = db.get(AlertChannels, uuid.UUID(ben["account_id"]))
    assert b"ben@" not in channels.email_enc
    client.delete("/notifications/email", headers=ben["headers"])
    client.delete("/notifications/push-token", headers=asha["headers"])
    assert client.get("/notifications/channels", headers=ben["headers"]).json()["email"] is False
    assert client.get("/notifications/channels", headers=asha["headers"]).json()["push"] is False


def test_alert_email_must_be_your_own_sign_in_email(client, people) -> None:
    resp = client.put(
        "/notifications/email", json={"email": "someone@else.com"}, headers=people["ben"]["headers"]
    )
    assert resp.status_code == 422 and resp.json()["detail"] == "email_must_match_sign_in"


def test_telegram_link_flow(client, db, redis, senders, people) -> None:
    link_telegram(client, db, redis, senders, people["ben"], chat_id=4242)
    assert senders.telegram.sent[-1][1].body.startswith("Linked.")
    assert client.get("/notifications/channels", headers=people["ben"]["headers"]).json()[
        "telegram"
    ]
    # an old or made-up link gets a polite "expired" reply and links nothing
    senders.telegram.updates = [
        {"update_id": 8, "message": {"text": "/start nope", "chat": {"id": 99}}}
    ]
    assert link_telegram_chats(db, redis, get_settings(), senders) == 0
    assert senders.telegram.sent[-1][0] == "99" and "expired" in senders.telegram.sent[-1][1].body
    assert redis.get("tg:offset") == b"9"
    # a bare /start (no link code) also gets that reply instead of silence
    senders.telegram.updates = [{"update_id": 9, "message": {"text": "/start", "chat": {"id": 98}}}]
    assert link_telegram_chats(db, redis, get_settings(), senders) == 0
    assert senders.telegram.sent[-1][0] == "98" and "expired" in senders.telegram.sent[-1][1].body


def test_telegram_link_needs_a_configured_bot(client, people) -> None:
    resp = client.post("/notifications/telegram/link", headers=people["ben"]["headers"])
    assert resp.status_code == 409  # no bot username in dev settings


@pytest.mark.parametrize(
    ("method", "path"),
    [
        ("get", "/notifications/channels"),
        ("put", "/notifications/push-token"),
        ("put", "/notifications/email"),
        ("post", "/notifications/telegram/link"),
        ("get", "/escalations/active"),
        ("post", f"/escalations/{uuid.uuid4()}/ack"),
        ("post", f"/escalations/{uuid.uuid4()}/resolve"),
    ],
)
def test_contact_endpoints_require_sign_in(client, method, path) -> None:
    assert getattr(client, method)(path).status_code == 401


# --- real senders against a fake network ---------------------------------------------------


def test_fcm_sender_authenticates_and_sends(tmp_path) -> None:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    key_file = tmp_path / "sa.json"
    key_file.write_text(
        json.dumps(
            {
                "private_key": pem,
                "client_email": "bot@demo.iam.gserviceaccount.com",
                "token_uri": "https://oauth2.googleapis.com/token",
            }
        )
    )
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request)
        if request.url.host == "oauth2.googleapis.com":
            return httpx.Response(200, json={"access_token": "ya29.x", "expires_in": 3600})
        return httpx.Response(200, json={"name": "projects/demo/messages/1"})

    settings = get_settings().model_copy(
        update={"fcm_project_id": "demo", "fcm_service_account_file": str(key_file)}
    )
    sender = FcmSender(settings, httpx.Client(transport=httpx.MockTransport(handler)))
    assert sender.configured()
    assert sender.send("device-token", Message("Title", "Body", "http://x/ack#t"))
    assert sender.send("device-token", Message("Title", "Body"))
    token_calls = [c for c in calls if c.url.host == "oauth2.googleapis.com"]
    assert len(token_calls) == 1  # access token cached
    send = calls[1]
    assert send.url.path == "/v1/projects/demo/messages:send"
    assert send.headers["Authorization"] == "Bearer ya29.x"
    body = json.loads(send.content)["message"]
    assert body["token"] == "device-token" and body["android"]["priority"] == "high"


def test_telegram_sender_posts_message() -> None:
    seen = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={"ok": True, "result": {}})

    settings = get_settings().model_copy(update={"telegram_bot_token": "123:abc"})
    sender = TelegramSender(settings, httpx.Client(transport=httpx.MockTransport(handler)))
    assert sender.send("555", Message("Title", "Body", "http://x/ack#t"))
    assert seen[0].url.path == "/bot123:abc/sendMessage"
    payload = json.loads(seen[0].content)
    assert payload["chat_id"] == "555" and "http://x/ack#t" in payload["text"]


def test_unconfigured_senders_report_it() -> None:
    settings = get_settings()
    assert not FcmSender(settings).configured()
    assert not TelegramSender(settings).configured()


# --- retention and privacy -----------------------------------------------------------------


def test_escalations_purged_after_90_days(client, db, senders, clock, people) -> None:
    start_journey(client, people["owner"], clock)
    silent_until_contact_alert(db, senders, clock)
    owner_id = uuid.UUID(people["owner"]["account_id"])
    db.execute(
        update(Escalation)
        .where(Escalation.owner_id == owner_id)
        .values(opened_at=T0 - timedelta(days=91))
    )
    assert ladder.purge_expired(db, T0) >= 1
    assert escalations(db, people["owner"]) == []


def test_nothing_personal_in_logs(client, db, redis, senders, clock, people, caplog) -> None:
    caplog.set_level(logging.DEBUG)
    link_telegram(client, db, redis, senders, people["asha"], chat_id=777123)
    start_journey(client, people["owner"], clock)
    silent_until_contact_alert(db, senders, clock)
    token = senders.push.sent[0][1].ack_url.split("#")[1]
    client.post("/escalations/ack", json={"token": token})
    for secret in ("asha-fcm", "ben@college.edu", "777123", token, "Priya"):
        assert secret not in caplog.text


# --- signed alerts (P2-W6) -----------------------------------------------------------------


def verify(client, data: dict[str, str]) -> dict:
    """What the app does: check the signature with the published key, then trust the JSON."""
    keys = client.get("/notifications/signing-keys").json()["keys"]
    key = next(k for k in keys if k["key_id"] == data["kid"])
    public = Ed25519PublicKey.from_public_bytes(base64.b64decode(key["ed25519_public_key"]))
    public.verify(base64.b64decode(data["sig"]), data["alert"].encode())
    return json.loads(data["alert"])


def test_push_alert_is_signed_and_verifiable(client, db, senders, clock, people) -> None:
    start_journey(client, people["owner"], clock)
    silent_until_contact_alert(db, senders, clock)
    _, message = senders.push.sent[0]
    alert = verify(client, message.data)
    [escalation] = escalations(db, people["owner"])
    assert alert == {
        "v": 1,
        "type": "alert",
        "escalation_id": str(escalation.id),
        "level": "contact_alert",
        "covert": False,
        "owner_label": "Priya",
        "opened_at": escalation.opened_at.isoformat(),
        "issued_at": clock.now.isoformat(),
        "code": message.code,
    }


def test_tampered_or_forged_alert_fails_verification(client, db, senders, clock, people) -> None:
    start_journey(client, people["owner"], clock)
    silent_until_contact_alert(db, senders, clock)
    data = dict(senders.push.sent[0][1].data)
    data["alert"] = data["alert"].replace("contact_alert", "full_escalation")
    with pytest.raises(InvalidSignature):
        verify(client, data)
    forged = Ed25519PrivateKey.generate()
    data["sig"] = base64.b64encode(forged.sign(data["alert"].encode())).decode()
    with pytest.raises(InvalidSignature):
        verify(client, data)


def test_people_get_a_code_the_app_also_shows(client, db, senders, clock, people) -> None:
    start_journey(client, people["owner"], clock)
    silent_until_contact_alert(db, senders, clock)
    _, email = senders.email.sent[0]  # Ben
    _, push = senders.push.sent[0]  # Asha
    assert f"Verification code: {email.code}" in email.text()
    assert re.fullmatch(r"[2-9A-HJKMNP-Z]{4}-[2-9A-HJKMNP-Z]{4}", email.code)
    for person, message in (("ben", email), ("asha", push)):
        shown = client.get("/escalations/active", headers=people[person]["headers"]).json()
        assert shown["escalations"][0]["verification_code"] == message.code
    assert email.code != push.code  # per contact, so one leaked code can't fake another's


def test_signing_keys_are_public_and_support_rotation(client) -> None:
    current = client.get("/notifications/signing-keys").json()["keys"]
    assert len(current) == 1 and current[0]["alg"] == "Ed25519"
    seed = base64.b64encode(os.urandom(32)).decode()
    rotated = get_settings().model_copy(
        update={
            "alert_signing_key": seed,
            "alert_signing_key_previous": get_settings().alert_signing_key,
        }
    )
    app.dependency_overrides[get_settings] = lambda: rotated
    keys = client.get("/notifications/signing-keys").json()["keys"]
    assert [k["key_id"] for k in keys][1] == current[0]["key_id"]  # old key still listed
    data = signing.sign({"type": "alert"}, rotated)
    assert data["kid"] == keys[0]["key_id"]
    assert verify(client, data) == {"type": "alert"}


def test_bad_signing_key_rejected() -> None:
    with pytest.raises(ValueError, match="32-byte"):
        signing._load(base64.b64encode(b"short").decode())


def test_fcm_push_carries_the_signed_alert(tmp_path) -> None:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    ).decode()
    key_file = tmp_path / "sa.json"
    key_file.write_text(
        json.dumps(
            {
                "private_key": pem,
                "client_email": "x@y",
                "token_uri": "https://oauth2.googleapis.com/token",
            }
        )
    )
    sent = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.host == "oauth2.googleapis.com":
            return httpx.Response(200, json={"access_token": "t", "expires_in": 3600})
        sent.append(json.loads(request.content))
        return httpx.Response(200, json={})

    settings = get_settings().model_copy(
        update={"fcm_project_id": "demo", "fcm_service_account_file": str(key_file)}
    )
    sender = FcmSender(settings, httpx.Client(transport=httpx.MockTransport(handler)))
    data = signing.sign({"type": "alert"}, settings)
    sender.send("device", Message("T", "B", "http://x/ack#t", code="AAAA-BBBB", data=data))
    assert sent[0]["message"]["data"] == {"ack_url": "http://x/ack#t", **data}


# --- demo hardening (P2-W1-demo-telegram-live) ---------------------------------------------


def test_telegram_retries_when_connecting_fails(monkeypatch) -> None:
    monkeypatch.setattr("app.notification.channels.time.sleep", lambda s: None)
    attempts = []

    def handler(request: httpx.Request) -> httpx.Response:
        attempts.append(request)
        if len(attempts) < 3:
            raise httpx.ConnectError("Connection reset by peer")
        return httpx.Response(200, json={"ok": True, "result": {}})

    settings = get_settings().model_copy(update={"telegram_bot_token": " 123:abc \n"})
    sender = TelegramSender(settings, httpx.Client(transport=httpx.MockTransport(handler)))
    assert sender.send("555", Message("T", "B"))
    assert len(attempts) == 3
    assert attempts[0].url.path == "/bot123:abc/sendMessage"  # stray whitespace stripped


def test_telegram_gives_up_after_three_connect_failures(monkeypatch) -> None:
    monkeypatch.setattr("app.notification.channels.time.sleep", lambda s: None)

    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectTimeout("slow TLS")

    settings = get_settings().model_copy(update={"telegram_bot_token": "123:abc"})
    sender = TelegramSender(settings, httpx.Client(transport=httpx.MockTransport(handler)))
    assert not sender.send("555", Message("T", "B"))


def test_telegram_does_not_resend_after_a_read_error(monkeypatch) -> None:
    attempts = []

    def handler(request: httpx.Request) -> httpx.Response:
        attempts.append(request)
        raise httpx.ReadTimeout("sent but no answer")

    settings = get_settings().model_copy(update={"telegram_bot_token": "123:abc"})
    sender = TelegramSender(settings, httpx.Client(transport=httpx.MockTransport(handler)))
    assert not sender.send("555", Message("T", "B"))
    assert len(attempts) == 1  # the message may have gone out; never send it twice


def test_telegram_link_tolerates_at_sign_in_username(client, people, senders) -> None:
    settings = get_settings().model_copy(update={"telegram_bot_username": " @sixthsense_bot "})
    app.dependency_overrides[get_settings] = lambda: settings
    url = client.post("/notifications/telegram/link", headers=people["ben"]["headers"]).json()[
        "url"
    ]
    assert url.startswith("https://t.me/sixthsense_bot?start=")
