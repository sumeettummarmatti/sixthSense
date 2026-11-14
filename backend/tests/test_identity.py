import base64
import logging
import uuid

import pytest
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from sqlalchemy import select, text
from sqlalchemy.exc import DBAPIError

from app.core.audit import AuditEvent
from app.core.config import Settings, get_settings
from app.identity import security
from app.identity.models import Account, Device
from app.identity.router import get_current_session

EMAIL = "Priya.Student@College.edu "


def new_device_key() -> tuple[ec.EllipticCurvePrivateKey, str]:
    private = ec.generate_private_key(ec.SECP256R1())
    der = private.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
    return private, base64.b64encode(der).decode()


def sign(private: ec.EllipticCurvePrivateKey, device_id: str, nonce: str) -> str:
    message = security.device_challenge_message(device_id, nonce)
    return base64.b64encode(private.sign(message, ec.ECDSA(hashes.SHA256()))).decode()


def request_code(client, mailer, email: str = EMAIL) -> str:
    resp = client.post("/auth/otp/request", json={"email": email})
    assert resp.status_code == 202
    return mailer.last_code()


def sign_in(client, mailer, email: str = EMAIL, public_key: str | None = None):
    private, generated = new_device_key()
    code = request_code(client, mailer, email)
    resp = client.post(
        "/auth/otp/verify",
        json={"email": email, "code": code, "device_public_key": public_key or generated},
    )
    return resp, private


def wrong(code: str) -> str:
    return f"{(int(code) + 1) % 1_000_000:06d}"


# --- email code -------------------------------------------------------------------------


def test_happy_path_creates_account_without_plaintext_email(client, mailer, db, redis) -> None:
    resp, _ = sign_in(client, mailer)
    assert resp.status_code == 200
    session = resp.json()
    assert session["token_type"] == "bearer"
    assert session["expires_in"] == 900
    assert mailer.sent[-1][0] == "priya.student@college.edu"  # normalised

    account = db.get(Account, uuid.UUID(session["account_id"]))
    assert account is not None and account.tier == 0
    assert account.email_hmac == security.email_hmac(get_settings().otp_pepper, EMAIL)
    assert b"college" not in account.email_hmac
    device = db.get(Device, uuid.UUID(session["device_id"]))
    assert device is not None and device.account_id == account.id

    actions = db.scalars(select(AuditEvent.action).where(AuditEvent.actor_account_id == account.id))
    assert set(actions) == {"device.registered", "auth.otp_verified"}

    current = get_current_session(get_settings(), redis, f"Bearer {session['access_token']}")
    assert str(current.account_id) == session["account_id"]


def test_same_email_and_device_signs_back_into_same_account(client, mailer) -> None:
    private, public_key = new_device_key()
    first, _ = sign_in(client, mailer, public_key=public_key)
    again, _ = sign_in(client, mailer, email="priya.student@college.edu", public_key=public_key)
    assert again.status_code == 200
    assert again.json()["account_id"] == first.json()["account_id"]
    assert again.json()["device_id"] == first.json()["device_id"]


def test_wrong_code_rejected_then_right_code_works(client, mailer) -> None:
    _, public_key = new_device_key()
    code = request_code(client, mailer)
    body = {"email": EMAIL, "device_public_key": public_key}
    resp = client.post("/auth/otp/verify", json={**body, "code": wrong(code)})
    assert resp.status_code == 400
    assert resp.json()["detail"] == "invalid_or_expired_code"
    assert client.post("/auth/otp/verify", json={**body, "code": code}).status_code == 200


def test_code_is_single_use(client, mailer) -> None:
    _, public_key = new_device_key()
    code = request_code(client, mailer)
    body = {"email": EMAIL, "code": code, "device_public_key": public_key}
    assert client.post("/auth/otp/verify", json=body).status_code == 200
    assert client.post("/auth/otp/verify", json=body).status_code == 400


def test_expired_code_rejected(client, mailer, redis) -> None:
    _, public_key = new_device_key()
    code = request_code(client, mailer)
    otp_key = f"otp:{security.email_hmac(get_settings().otp_pepper, EMAIL).hex()}"
    assert 590 <= redis.ttl(otp_key) <= 600
    redis.delete(otp_key)  # what Redis does when the 10-minute TTL runs out
    resp = client.post(
        "/auth/otp/verify", json={"email": EMAIL, "code": code, "device_public_key": public_key}
    )
    assert resp.status_code == 400


def test_too_many_attempts_locks_the_code(client, mailer) -> None:
    _, public_key = new_device_key()
    code = request_code(client, mailer)
    body = {"email": EMAIL, "device_public_key": public_key}
    for _ in range(5):
        resp = client.post("/auth/otp/verify", json={**body, "code": wrong(code)})
        assert resp.status_code == 400
    resp = client.post("/auth/otp/verify", json={**body, "code": code})
    assert resp.status_code == 429
    assert resp.json()["detail"] == "too_many_attempts"


def test_rate_limit_per_email(client, mailer) -> None:
    for _ in range(3):
        assert client.post("/auth/otp/request", json={"email": EMAIL}).status_code == 202
    resp = client.post("/auth/otp/request", json={"email": EMAIL})
    assert resp.status_code == 429
    assert resp.headers["Retry-After"] == "600"
    assert len(mailer.sent) == 3


def test_rate_limit_per_ip(client) -> None:
    for i in range(10):
        resp = client.post("/auth/otp/request", json={"email": f"user{i}@college.edu"})
        assert resp.status_code == 202
    assert client.post("/auth/otp/request", json={"email": "user10@college.edu"}).status_code == 429


def test_same_response_for_known_and_unknown_email(client, mailer) -> None:
    sign_in(client, mailer, email="known@college.edu")
    known = client.post("/auth/otp/request", json={"email": "known@college.edu"})
    unknown = client.post("/auth/otp/request", json={"email": "nobody@college.edu"})
    assert known.status_code == unknown.status_code == 202
    assert known.json() == unknown.json() == {"status": "sent"}
    assert known.headers.keys() == unknown.headers.keys()


@pytest.mark.parametrize(
    "bad_key",
    [
        "not base64!",
        base64.b64encode(b"junk").decode(),
        base64.b64encode(
            ec.generate_private_key(ec.SECP384R1())
            .public_key()
            .public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
        ).decode(),
        base64.b64encode(
            rsa.generate_private_key(public_exponent=65537, key_size=2048)
            .public_key()
            .public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
        ).decode(),
    ],
)
def test_only_p256_device_keys_accepted_and_code_not_burned(client, mailer, bad_key) -> None:
    code = request_code(client, mailer)
    resp = client.post(
        "/auth/otp/verify", json={"email": EMAIL, "code": code, "device_public_key": bad_key}
    )
    assert resp.status_code == 422
    _, good_key = new_device_key()
    resp = client.post(
        "/auth/otp/verify", json={"email": EMAIL, "code": code, "device_public_key": good_key}
    )
    assert resp.status_code == 200


def test_device_key_cannot_move_to_another_account(client, mailer) -> None:
    _, public_key = new_device_key()
    assert sign_in(client, mailer, public_key=public_key)[0].status_code == 200
    resp, _ = sign_in(client, mailer, email="someone.else@college.edu", public_key=public_key)
    assert resp.status_code == 409


# --- device-bound sign-in --------------------------------------------------------------


def device_sign_in(client, device_id: str, signer) -> tuple[int, str]:
    nonce = client.post("/auth/device/challenge", json={"device_id": device_id}).json()["nonce"]
    resp = client.post(
        "/auth/device/verify",
        json={"device_id": device_id, "nonce": nonce, "signature": signer(device_id, nonce)},
    )
    return resp.status_code, nonce


def test_device_challenge_signed_by_bound_key_signs_in(client, mailer, db) -> None:
    resp, private = sign_in(client, mailer)
    device_id = resp.json()["device_id"]
    challenge = client.post("/auth/device/challenge", json={"device_id": device_id})
    assert challenge.status_code == 200 and challenge.json()["expires_in"] == 120
    nonce = challenge.json()["nonce"]
    body = {"device_id": device_id, "nonce": nonce, "signature": sign(private, device_id, nonce)}
    signed_in = client.post("/auth/device/verify", json=body)
    assert signed_in.status_code == 200
    assert signed_in.json()["account_id"] == resp.json()["account_id"]
    assert signed_in.json()["access_token"] != resp.json()["access_token"]
    assert "auth.device_signin" in set(db.scalars(select(AuditEvent.action)))

    # the nonce is single use
    assert client.post("/auth/device/verify", json=body).status_code == 401


def test_device_challenge_rejects_other_key(client, mailer) -> None:
    resp, _ = sign_in(client, mailer)
    impostor, _ = new_device_key()
    status_code, _ = device_sign_in(
        client, resp.json()["device_id"], lambda d, n: sign(impostor, d, n)
    )
    assert status_code == 401


def test_device_challenge_rejects_signature_over_wrong_message(client, mailer) -> None:
    resp, private = sign_in(client, mailer)
    status_code, _ = device_sign_in(
        client, resp.json()["device_id"], lambda d, n: sign(private, d, n + "x")
    )
    assert status_code == 401


def test_device_challenge_is_bound_to_its_device(client, mailer) -> None:
    first, private = sign_in(client, mailer)
    second, _ = sign_in(client, mailer, email="other@college.edu")
    nonce = client.post(
        "/auth/device/challenge", json={"device_id": second.json()["device_id"]}
    ).json()["nonce"]
    device_id = first.json()["device_id"]
    resp = client.post(
        "/auth/device/verify",
        json={"device_id": device_id, "nonce": nonce, "signature": sign(private, device_id, nonce)},
    )
    assert resp.status_code == 401


def test_unknown_device_gets_a_challenge_but_cannot_sign_in(client) -> None:
    private, _ = new_device_key()
    status_code, _ = device_sign_in(client, str(uuid.uuid4()), lambda d, n: sign(private, d, n))
    assert status_code == 401


def test_bad_bearer_token_rejected(redis) -> None:
    from fastapi import HTTPException

    for header in (None, "Bearer nope", "Basic abc"):
        with pytest.raises(HTTPException) as exc:
            get_current_session(get_settings(), redis, header)
        assert exc.value.status_code == 401


# --- privacy -----------------------------------------------------------------------------


def test_nothing_sensitive_in_logs_or_redis(client, mailer, redis, caplog) -> None:
    caplog.set_level(logging.DEBUG)
    private, public_key = new_device_key()
    code = request_code(client, mailer)
    body = {"email": EMAIL, "device_public_key": public_key}
    client.post("/auth/otp/verify", json={**body, "code": wrong(code)})
    session = client.post("/auth/otp/verify", json={**body, "code": code}).json()
    status_code, nonce = device_sign_in(
        client, session["device_id"], lambda d, n: sign(private, d, n)
    )
    assert status_code == 200

    secrets_seen = [EMAIL.strip(), EMAIL.strip().lower(), code, public_key, nonce]
    secrets_seen.append(session["access_token"])
    logs = caplog.text.lower()
    stored = b" ".join(
        [key for key in redis.keys("*")]
        + [str(redis.dump(key)).encode() for key in redis.keys("*")]
    ).lower()
    for secret in secrets_seen:
        assert secret.lower() not in logs
        assert secret.lower().encode() not in stored


def test_audit_log_is_append_only(client, mailer, db) -> None:
    sign_in(client, mailer)
    for statement in ("UPDATE audit_events SET action = 'x'", "DELETE FROM audit_events"):
        with pytest.raises(DBAPIError, match="append-only"):
            with db.begin_nested():
                db.execute(text(statement))


def test_dev_secrets_refused_outside_dev() -> None:
    # _env_file=None: judge the defaults, not whatever real secrets are in this machine's .env
    with pytest.raises(ValueError, match="OTP_PEPPER"):
        Settings(_env_file=None, env="prod")
    with pytest.raises(ValueError, match="DATA_KEY"):
        Settings(
            _env_file=None,
            env="prod",
            otp_pepper="real-pepper",
            token_secret="real-secret",
        )
    real = {
        "otp_pepper": "p",
        "token_secret": "t",
        "data_key": "d",
        "identity_hmac_secret": "identity-secret",
        "face_template_key": "a-real-face-template-key-of-32-chars-or-more",
    }
    with pytest.raises(ValueError, match="ALERT_SIGNING_KEY"):
        Settings(_env_file=None, env="prod", **real)
    Settings(_env_file=None, env="prod", **real, alert_signing_key="cmVhbC1rZXk=")
