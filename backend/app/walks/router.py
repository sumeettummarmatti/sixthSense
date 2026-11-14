"""Walk With Me API (P3-W3).

Companions:  POST /walks/companion/join, GET /walks/companion/me,
             PUT|DELETE /walks/companion/presence
Travellers:  POST /walks/search, POST /walks (ask)
Companions:  GET /walks/requests, POST /walks/{id}/accept (with a fresh face scan)|decline
Both:        GET /walks/current, POST /walks/{id}/end; traveller: POST /walks/{id}/cancel

A traveller sees only companions who chose to be available, and only while on an open journey;
a companion sees a traveller's first name and rough area only after being asked (rule 4).

Companions use the same identity verification as responders (ID + selfie, /verification); there
is no approval step. Every accept carries a fresh face scan (app.face_scan) in the same request,
so the traveller's location is only shared once the person holding the phone has been checked.
"""

import uuid
from datetime import UTC, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, File, HTTPException, Response, UploadFile, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from app.core import audit
from app.escalation import helpers
from app.face_scan import service as face_scan
from app.identity.router import CurrentSessionDep, DbDep, RedisDep, SettingsDep
from app.journey.models import Journey
from app.journey.state import State
from app.matching import nearby
from app.notification.channels import Message, Senders, get_senders
from app.profiles.models import Profile
from app.profiles.schemas import PartnerProfile
from app.verification.eligibility import eligible, verified_identity
from app.walks import schemas, service
from app.walks.models import CompanionProfile, Walk

router = APIRouter(prefix="/walks", tags=["walks"])

SendersDep = Annotated[Senders, Depends(get_senders)]
_WALK_NOT_FOUND = HTTPException(status.HTTP_404_NOT_FOUND, "walk_not_found")


def _now() -> datetime:
    return datetime.now(UTC)


NowDep = Annotated[datetime, Depends(_now)]


def _partner(profile: Profile | None) -> PartnerProfile | None:
    if profile is None:
        return None
    return PartnerProfile(
        first_name=profile.first_name,
        bio=profile.bio,
        strengths=list(profile.strengths),
        languages=list(profile.languages),
    )


def _rounded(meters: int) -> int:
    return max(100, round(meters / 100) * 100)


# --- companion side ------------------------------------------------------------------------


def _companion_me(db, redis, settings, account_id, now) -> schemas.CompanionMe:
    identity_verified = verified_identity(db, account_id, now) is not None
    profile = db.get(CompanionProfile, account_id)
    if profile is None:
        return schemas.CompanionMe(status="none", identity_verified=identity_verified)
    return schemas.CompanionMe(
        status=profile.status,
        identity_verified=identity_verified,
        verified_method=profile.verified_method,
        verified_at=profile.verified_at,
        available=service.presence_of(redis, account_id, settings, now) is not None,
    )


@router.post("/companion/join", response_model=schemas.CompanionMe)
def join(
    session: CurrentSessionDep, db: DbDep, redis: RedisDep, settings: SettingsDep, now: NowDep
) -> schemas.CompanionMe:
    """Become a companion. Needs the profile's "willing to be a companion" and a verified
    identity (409 identity_not_verified: the app opens identity verification). No approval."""
    profile = db.get(Profile, session.account_id)
    if profile is None or not profile.willing_companion:
        raise HTTPException(status.HTTP_409_CONFLICT, "profile_not_willing")
    identity = verified_identity(db, session.account_id, now)
    if identity is None:
        raise HTTPException(status.HTTP_409_CONFLICT, "identity_not_verified")
    companion = db.get(CompanionProfile, session.account_id)
    if companion is not None and companion.status == "revoked":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "companion_revoked")
    if companion is None:
        companion = CompanionProfile(account_id=session.account_id)
        db.add(companion)
    companion.status, companion.approved_at = "approved", now
    companion.verified_method, companion.verified_at = "identity", identity.verified_at
    audit.record(db, "companion.joined", actor=session.account_id)
    db.commit()
    return _companion_me(db, redis, settings, session.account_id, now)


@router.get("/companion/me", response_model=schemas.CompanionMe)
def companion_me(
    session: CurrentSessionDep, db: DbDep, redis: RedisDep, settings: SettingsDep, now: NowDep
) -> schemas.CompanionMe:
    return _companion_me(db, redis, settings, session.account_id, now)


@router.put("/companion/presence", response_model=schemas.Available)
def go_available(
    body: schemas.Area,
    session: CurrentSessionDep,
    db: DbDep,
    redis: RedisDep,
    settings: SettingsDep,
    now: NowDep,
) -> schemas.Available:
    """Available: refresh about once a minute. Rounded to ~110 m, forgotten after 5 minutes."""
    if not eligible(db, session.account_id, "companion", now):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "not_eligible")
    profile = db.get(Profile, session.account_id)
    if profile is None or not profile.willing_companion:
        raise HTTPException(status.HTTP_409_CONFLICT, "profile_not_willing")
    service.set_presence(
        redis, session.account_id, nearby.rough(body.latitude, body.longitude), now
    )
    return schemas.Available(
        available=True, expires_in_seconds=settings.companion_presence_ttl_seconds
    )


@router.delete("/companion/presence", status_code=status.HTTP_204_NO_CONTENT)
def go_unavailable(session: CurrentSessionDep, redis: RedisDep) -> Response:
    service.clear_presence(redis, session.account_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# --- traveller side ------------------------------------------------------------------------


def _open_journey(db, account_id: uuid.UUID, journey_id: uuid.UUID) -> Journey:
    journey = db.get(Journey, journey_id)
    if journey is None or journey.account_id != account_id or journey.state == State.RESOLVED:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no_open_journey")
    return journey


def _busy(db, now) -> set[uuid.UUID]:
    """Companions already in an accepted walk or holding a live request."""
    rows = db.scalars(select(Walk).where(Walk.status.in_(service.OPEN)))
    return {
        walk.companion_id for walk in rows if walk.status == "accepted" or walk.expires_at > now
    }


@router.post("/search", response_model=schemas.Companions)
def search(
    body: schemas.Search,
    session: CurrentSessionDep,
    db: DbDep,
    redis: RedisDep,
    settings: SettingsDep,
    now: NowDep,
) -> schemas.Companions:
    """Eligible companions who are available nearby, nearest first. Needs an open journey, so
    nobody can browse companions casually. Coordinates go in the body, never in the URL."""
    _open_journey(db, session.account_id, body.journey_id)
    here = nearby.rough(body.latitude, body.longitude)
    duty = service.available(redis, settings, now)
    duty.pop(session.account_id, None)
    if not duty:
        return schemas.Companions(companions=[])
    busy = _busy(db, now)
    rows = db.execute(
        select(CompanionProfile, Profile)
        .join(Profile, Profile.account_id == CompanionProfile.account_id)
        .where(
            CompanionProfile.status != "revoked",
            CompanionProfile.account_id.in_(list(duty)),
            Profile.willing_companion.is_(True),
        )
    ).all()
    cards = []
    for companion, profile in rows:
        if companion.account_id in busy or not eligible(
            db, companion.account_id, "companion", now
        ):
            continue
        if body.women_only and profile.gender != "woman":
            continue
        meters = nearby.distance_m(here, duty[companion.account_id])
        if meters > settings.walk_search_radius_m:
            continue
        rating, count = service.rating_of(db, companion.account_id)
        cards.append(
            schemas.CompanionCard(
                companion_id=companion.account_id,
                profile=_partner(profile),
                rating=rating,
                rating_count=count,
                distance_m=_rounded(meters),
                walk_minutes=nearby.walk_minutes(meters),
            )
        )
    cards.sort(key=lambda card: card.distance_m)
    audit.record(db, "walk.searched", actor=session.account_id)
    db.commit()
    return schemas.Companions(companions=cards[: settings.walk_max_results])


def _notify(db, senders: Senders, account: uuid.UUID, message: Message) -> None:
    from app.escalation.ladder import _deliver  # same delivery as alerts (push, then Telegram)

    for channel in ("push", "telegram"):
        if _deliver(db, senders, channel, account, message):
            return


@router.post("", response_model=schemas.WalkView, status_code=status.HTTP_201_CREATED)
def ask(
    body: schemas.AskIn,
    session: CurrentSessionDep,
    db: DbDep,
    redis: RedisDep,
    settings: SettingsDep,
    senders: SendersDep,
    now: NowDep,
) -> schemas.WalkView:
    """'Ask to walk with me.' The companion gets the traveller's first name and rough area."""
    journey = _open_journey(db, session.account_id, body.journey_id)
    traveller = db.get(Profile, session.account_id)
    if traveller is None:
        raise HTTPException(status.HTTP_409_CONFLICT, "no_profile")
    if body.companion_id == session.account_id:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "cannot_ask_yourself")
    for walk in service.open_walks_of(db, session.account_id):
        service.refresh(db, redis, walk, now)
    companion_area = service.presence_of(redis, body.companion_id, settings, now)
    if (
        companion_area is None
        or not eligible(db, body.companion_id, "companion", now)
        or body.companion_id in _busy(db, now)
    ):
        raise HTTPException(status.HTTP_409_CONFLICT, "companion_unavailable")
    walk = Walk(
        journey_id=journey.id,
        traveller_id=session.account_id,
        companion_id=body.companion_id,
        status="requested",
        requested_at=now,
        expires_at=now + timedelta(seconds=settings.walk_request_ttl_seconds),
    )
    db.add(walk)
    try:
        db.flush()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status.HTTP_409_CONFLICT, "walk_already_open") from None
    area = nearby.rough(body.latitude, body.longitude)
    service.set_area(redis, walk.id, area, settings)
    meters = nearby.distance_m(area, companion_area)
    audit.record(db, "walk.requested", actor=session.account_id, target=f"walk:{walk.id}")
    _notify(
        db,
        senders,
        body.companion_id,
        Message(
            "SixthSense: someone asked to walk with you",
            f"{traveller.first_name}, about {_rounded(meters)} m away, asked you to walk with "
            "them. Open SixthSense > Walk With Me to accept or decline within 10 minutes.",
        ),
    )
    db.commit()
    return _view(db, redis, settings, walk, session.account_id)


@router.get("/requests", response_model=schemas.WalkRequests)
def requests(
    session: CurrentSessionDep, db: DbDep, redis: RedisDep, settings: SettingsDep, now: NowDep
) -> schemas.WalkRequests:
    """Requests waiting for me (companion). Empty for everyone else."""
    walks = db.scalars(
        select(Walk)
        .where(Walk.companion_id == session.account_id, Walk.status == "requested")
        .order_by(Walk.requested_at)
    ).all()
    mine = service.presence_of(redis, session.account_id, settings, now)
    out = []
    for walk in walks:
        if service.refresh(db, redis, walk, now).status != "requested":
            continue
        area = service.area_of(redis, walk.id)
        out.append(
            schemas.WalkRequest(
                id=walk.id,
                traveller_first_name=_first_name(db, walk.traveller_id),
                rough_area=schemas.Area(latitude=area.latitude, longitude=area.longitude)
                if area
                else None,
                distance_m=_rounded(nearby.distance_m(area, mine)) if area and mine else None,
                expires_at=walk.expires_at,
            )
        )
    db.commit()
    return schemas.WalkRequests(requests=out)


def _first_name(db, account_id: uuid.UUID) -> str:
    profile = db.get(Profile, account_id)
    return profile.first_name if profile else "A traveller"


def _walk_for(db, walk_id: uuid.UUID, account_id: uuid.UUID, role: str) -> Walk:
    walk = db.scalars(select(Walk).where(Walk.id == walk_id).with_for_update()).first()
    if walk is None:
        raise _WALK_NOT_FOUND
    owner = walk.companion_id if role == "companion" else walk.traveller_id
    if role == "either":
        if account_id not in (walk.companion_id, walk.traveller_id):
            raise _WALK_NOT_FOUND
    elif owner != account_id:
        raise _WALK_NOT_FOUND
    return walk


@router.post("/{walk_id}/accept", response_model=schemas.WalkView)
def accept(
    walk_id: uuid.UUID,
    session: CurrentSessionDep,
    db: DbDep,
    redis: RedisDep,
    settings: SettingsDep,
    senders: SendersDep,
    now: NowDep,
    selfie_image: Annotated[UploadFile | None, File()] = None,
) -> schemas.WalkView:
    """Accept, with a fresh face scan (multipart `selfie_image`) in the same request. Only a
    passing scan accepts the walk and opens the two-way live location (428 face_scan_required,
    403 face_mismatch)."""
    walk = _walk_for(db, walk_id, session.account_id, "companion")
    service.refresh(db, redis, walk, now)
    if walk.status != "requested":
        db.commit()
        raise HTTPException(status.HTTP_409_CONFLICT, f"walk_{walk.status}")
    if not eligible(db, session.account_id, "companion", now):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "not_eligible")
    if service.accepted_walk_for_companion(db, session.account_id) is not None:
        raise HTTPException(status.HTTP_409_CONFLICT, "already_walking")
    image, content_type = face_scan.read_scan(selfie_image)
    face_scan.check(
        db, settings, session.account_id, "walk", image, content_type, now, f"walk:{walk.id}"
    )
    walk.status, walk.responded_at = "accepted", now
    audit.record(db, "walk.accepted", actor=session.account_id, target=f"walk:{walk.id}")
    _notify(
        db,
        senders,
        walk.traveller_id,
        Message(
            "SixthSense: your walk was accepted",
            f"{_first_name(db, session.account_id)} will walk with you. Open SixthSense to see "
            "the handshake code and check it matches before you set off.",
        ),
    )
    db.commit()
    return _view(db, redis, settings, walk, session.account_id)


@router.post("/{walk_id}/decline", status_code=status.HTTP_204_NO_CONTENT)
def decline(
    walk_id: uuid.UUID, session: CurrentSessionDep, db: DbDep, redis: RedisDep, now: NowDep
) -> Response:
    walk = _walk_for(db, walk_id, session.account_id, "companion")
    service.refresh(db, redis, walk, now)
    if walk.status == "requested":
        walk.status, walk.responded_at = "declined", now
        service.clear_area(redis, walk.id)
        audit.record(db, "walk.declined", actor=session.account_id, target=f"walk:{walk.id}")
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/{walk_id}/cancel", status_code=status.HTTP_204_NO_CONTENT)
def cancel(
    walk_id: uuid.UUID, session: CurrentSessionDep, db: DbDep, redis: RedisDep, now: NowDep
) -> Response:
    """The traveller withdraws a request nobody has answered yet."""
    walk = _walk_for(db, walk_id, session.account_id, "traveller")
    service.refresh(db, redis, walk, now)
    if walk.status == "requested":
        walk.status = "cancelled"
        service.clear_area(redis, walk.id)
        audit.record(db, "walk.cancelled", actor=session.account_id, target=f"walk:{walk.id}")
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/{walk_id}/end", response_model=schemas.WalkView)
def end_walk(
    walk_id: uuid.UUID,
    session: CurrentSessionDep,
    db: DbDep,
    redis: RedisDep,
    settings: SettingsDep,
    now: NowDep,
) -> schemas.WalkView:
    """Either side ends the walk. The traveller's journey (check-ins, SOS) keeps running."""
    walk = _walk_for(db, walk_id, session.account_id, "either")
    service.refresh(db, redis, walk, now)
    if walk.status != "accepted":
        db.commit()
        raise HTTPException(status.HTTP_409_CONFLICT, f"walk_{walk.status}")
    role = "traveller" if walk.traveller_id == session.account_id else "companion"
    service.end(db, redis, walk, role, now)
    db.commit()
    return _view(db, redis, settings, walk, session.account_id)


@router.get("/current", response_model=schemas.WalkView)
def current(
    session: CurrentSessionDep, db: DbDep, redis: RedisDep, settings: SettingsDep, now: NowDep
) -> schemas.WalkView:
    """My open walk (requested or accepted), as traveller or companion; 404 `no_walk`."""
    found = None
    for walk in service.open_walks_of(db, session.account_id):
        service.refresh(db, redis, walk, now)
        if walk.status == "accepted" or (
            walk.status == "requested" and walk.traveller_id == session.account_id
        ):
            found = walk
    db.commit()
    if found is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "no_walk")
    return _view(db, redis, settings, found, session.account_id)


@router.get("/{walk_id}", response_model=schemas.WalkView)
def get_walk(
    walk_id: uuid.UUID,
    session: CurrentSessionDep,
    db: DbDep,
    redis: RedisDep,
    settings: SettingsDep,
    now: NowDep,
) -> schemas.WalkView:
    """One of my walks, including after it ended (so the app can show how it ended)."""
    walk = _walk_for(db, walk_id, session.account_id, "either")
    service.refresh(db, redis, walk, now)
    db.commit()
    return _view(db, redis, settings, walk, session.account_id)


def _view(db, redis, settings, walk: Walk, account_id: uuid.UUID) -> schemas.WalkView:
    role = "traveller" if walk.traveller_id == account_id else "companion"
    other = walk.companion_id if role == "traveller" else walk.traveller_id
    accepted = walk.status == "accepted"
    # A companion learns the traveller's profile only by accepting; the traveller chose the
    # companion from their card, so sees it from the request on.
    show_partner = accepted or role == "traveller"
    area = service.area_of(redis, walk.id) if walk.status in service.OPEN else None
    return schemas.WalkView(
        id=walk.id,
        role=role,
        status=walk.status,
        journey_id=walk.journey_id if role == "traveller" else None,
        partner=_partner(db.get(Profile, other)) if show_partner else None,
        handshake_code=service.handshake_code(settings, walk.id) if accepted else None,
        meet_near=schemas.Area(latitude=area.latitude, longitude=area.longitude)
        if area and accepted
        else None,
        partner_keys=helpers.device_keys(db, other) if accepted else [],
        expires_at=walk.expires_at,
        ended_at=walk.ended_at,
        end_reason=walk.end_reason,
    )
