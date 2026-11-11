import uuid
from datetime import datetime

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    SmallInteger,
    Text,
    Uuid,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import ARRAY
from sqlalchemy.orm import Mapped, mapped_column

from app.core.db import Base
from app.journey.state import JourneyState, Outcome, State, Timers


class TimerColumns:
    """Protocol timers in minutes. Protocols hold the owner's choice; journeys keep a copy."""

    check_in_interval_min: Mapped[int] = mapped_column(SmallInteger, server_default="15")
    check_in_grace_min: Mapped[int] = mapped_column(SmallInteger, server_default="2")
    prompt_timeout_min: Mapped[int] = mapped_column(SmallInteger, server_default="2")
    contact_response_min: Mapped[int] = mapped_column(SmallInteger, server_default="5")
    heartbeat_timeout_min: Mapped[int] = mapped_column(SmallInteger, server_default="10")
    auto_112: Mapped[bool] = mapped_column(Boolean, server_default="false")
    # trusted_contacts ids to alert; NULL = every accepted contact
    alert_contact_ids: Mapped[list[uuid.UUID] | None] = mapped_column(ARRAY(Uuid))

    def timers(self) -> Timers:
        return Timers(
            check_in_interval=self.check_in_interval_min,
            check_in_grace=self.check_in_grace_min,
            prompt_timeout=self.prompt_timeout_min,
            contact_response=self.contact_response_min,
            heartbeat_timeout=self.heartbeat_timeout_min,
        )


class Protocol(TimerColumns, Base):
    """The owner's journey settings (HLD §8). One per account."""

    __tablename__ = "protocols"

    account_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("accounts.id", ondelete="CASCADE"), primary_key=True
    )
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class Journey(TimerColumns, Base):
    """One journey. No destination, route or location is stored (rule 2). Kept 7 days.

    At most one visible open journey per account. A covert escalation the phone believes has
    ended doesn't count, so the owner can start a new journey without revealing it.
    """

    __tablename__ = "journeys"
    __table_args__ = (
        CheckConstraint(
            "state IN ('active', 'check_in_due', 'private_prompt', 'contact_alert', "
            "'full_escalation', 'resolved')",
            name="journeys_state_valid",
        ),
        Index(
            "uq_journeys_one_open_per_account",
            "account_id",
            unique=True,
            postgresql_where=text("state <> 'resolved' AND NOT covert"),
        ),
        Index(
            "ix_journeys_unresolved_state", "state", postgresql_where=text("state <> 'resolved'")
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, server_default=func.gen_random_uuid())
    account_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("accounts.id", ondelete="CASCADE"))
    state: Mapped[str] = mapped_column(Text)
    covert: Mapped[bool] = mapped_column(Boolean, server_default="false")
    outcome: Mapped[str | None] = mapped_column(Text)
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    next_check_in_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    last_heartbeat_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    state_changed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    cover_ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    alert_acknowledged_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    def to_state(self) -> JourneyState:
        return JourneyState(
            state=State(self.state),
            covert=self.covert,
            next_check_in_at=self.next_check_in_at,
            last_heartbeat_at=self.last_heartbeat_at,
            state_changed_at=self.state_changed_at,
            outcome=Outcome(self.outcome) if self.outcome else None,
            cover_ended_at=self.cover_ended_at,
            alert_acknowledged_at=self.alert_acknowledged_at,
        )

    def load_state(self, journey: JourneyState) -> None:
        self.state = journey.state.value
        self.covert = journey.covert
        self.next_check_in_at = journey.next_check_in_at
        self.last_heartbeat_at = journey.last_heartbeat_at
        self.state_changed_at = journey.state_changed_at
        self.outcome = journey.outcome.value if journey.outcome else None
        self.cover_ended_at = journey.cover_ended_at
        self.alert_acknowledged_at = journey.alert_acknowledged_at
        if journey.state == State.RESOLVED and self.ended_at is None:
            self.ended_at = journey.state_changed_at
