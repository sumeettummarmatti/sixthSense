from collections.abc import Callable, Iterator
from contextlib import AbstractContextManager

from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from app.core.config import get_settings


class Base(DeclarativeBase):
    """Declarative base for all Core-zone models."""


engine = create_engine(get_settings().core_database_url, pool_pre_ping=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


def get_db() -> Iterator[Session]:
    """FastAPI dependency: one session per request, committed by the handler."""
    with SessionLocal() as session:
        yield session


def get_session_factory() -> Callable[[], AbstractContextManager[Session]]:
    """For long-lived handlers (the relay WebSocket) that open a short session per message."""
    return SessionLocal
