"""Shared fixtures. Identity tests need the local core-db running (README step 6);
Redis is faked in memory and emails are captured instead of sent."""

from collections.abc import Iterator

import fakeredis
import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app.core.db import engine, get_db
from app.core.redis import get_redis
from app.identity.mailer import get_mailer
from app.main import app


class FakeMailer:
    def __init__(self) -> None:
        self.sent: list[tuple[str, str]] = []

    def send_sign_in_code(self, to: str, code: str) -> None:
        self.sent.append((to, code))

    def last_code(self) -> str:
        return self.sent[-1][1]


@pytest.fixture
def db() -> Iterator[Session]:
    """A session whose commits become savepoints; everything is rolled back after the test."""
    with engine.connect() as connection:
        transaction = connection.begin()
        session = Session(bind=connection, join_transaction_mode="create_savepoint")
        try:
            yield session
        finally:
            session.close()
            transaction.rollback()


@pytest.fixture
def redis() -> fakeredis.FakeRedis:
    return fakeredis.FakeRedis()


@pytest.fixture
def mailer() -> FakeMailer:
    return FakeMailer()


@pytest.fixture
def client(db: Session, redis: fakeredis.FakeRedis, mailer: FakeMailer) -> Iterator[TestClient]:
    app.dependency_overrides[get_db] = lambda: db
    app.dependency_overrides[get_redis] = lambda: redis
    app.dependency_overrides[get_mailer] = lambda: mailer
    try:
        yield TestClient(app)
    finally:
        app.dependency_overrides.clear()


@pytest.fixture
def make_user(client: TestClient, mailer: FakeMailer):
    """Sign a new user in through the real email-code flow; returns their auth headers + ids."""
    import base64

    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

    def _make(email: str) -> dict:
        key = ec.generate_private_key(ec.SECP256R1())
        public_key = base64.b64encode(
            key.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
        ).decode()
        client.post("/auth/otp/request", json={"email": email})
        session = client.post(
            "/auth/otp/verify",
            json={"email": email, "code": mailer.last_code(), "device_public_key": public_key},
        ).json()
        return {
            "headers": {"Authorization": f"Bearer {session['access_token']}"},
            "account_id": session["account_id"],
            "device_id": session["device_id"],
        }

    return _make
