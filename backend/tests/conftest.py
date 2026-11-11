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
