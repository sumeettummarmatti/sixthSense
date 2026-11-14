"""Shared fixtures. Tests need the local core-db running (README step 6) but use their own
database, `<core db>_test`, created and migrated here, so data from manual runs in the dev
database can never leak into a test. Redis is faked in memory and emails are captured."""

import os
from collections.abc import Iterator

from sqlalchemy.engine import make_url

from app.core.config import Settings

_dev_url = make_url(Settings().core_database_url)
_test_url = _dev_url.set(database=f"{_dev_url.database}_test")
os.environ["CORE_DATABASE_URL"] = _test_url.render_as_string(hide_password=False)
# Tests never talk to real Telegram/Firebase, whatever a developer's .env holds.
for _name in (
    "TELEGRAM_BOT_TOKEN",
    "TELEGRAM_BOT_USERNAME",
    "FCM_PROJECT_ID",
    "FCM_SERVICE_ACCOUNT_FILE",
):
    os.environ[_name] = ""
# Tests choose face matching themselves, whatever a developer's .env says (FACE_MATCHER=mock
# on laptops without CompreFace).
os.environ["FACE_MATCHER"] = "compreface"
os.environ["FACE_CHECK_PROVIDER"] = "mock"


def _create_and_migrate_test_db() -> None:
    import psycopg
    from alembic import command
    from alembic.config import Config

    admin = _dev_url.set(drivername="postgresql", database="postgres")
    with psycopg.connect(admin.render_as_string(hide_password=False), autocommit=True) as conn:
        exists = conn.execute(
            "SELECT 1 FROM pg_database WHERE datname = %s", (_test_url.database,)
        ).fetchone()
        if not exists:
            conn.execute(f'CREATE DATABASE "{_test_url.database}"')
    command.upgrade(Config(os.path.join(os.path.dirname(__file__), "..", "alembic.ini")), "head")


_create_and_migrate_test_db()

import fakeredis  # noqa: E402
import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from sqlalchemy.orm import Session  # noqa: E402

from app.core.db import engine, get_db  # noqa: E402
from app.core.redis import get_redis  # noqa: E402
from app.identity.mailer import get_mailer  # noqa: E402
from app.main import app  # noqa: E402


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
