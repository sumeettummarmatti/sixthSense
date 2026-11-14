"""Simulated responders for demos and testing (P3-W1). Not used in production.

Five real accounts (real sign-in, real E2E keys) go on duty around a centre point. When an SOS
comes, they behave like people: some say "I'm going" and walk to the traveller along real
streets, sending end-to-end encrypted live location; some decline; some don't answer.

Needs the API + worker + Mailpit running (sign-up codes are read from Mailpit).

    cd backend && uv run python scripts/sim_responders.py                  # normal
    cd backend && uv run python scripts/sim_responders.py --scenario slow  # radius grows
    cd backend && uv run python scripts/sim_responders.py --scenario far   # only far ones
    cd backend && uv run python scripts/sim_responders.py --scenario busy  # all say no
    options: --center 12.8907,77.5827  --speed 3 (x walking speed)  --api http://localhost:8000

Ctrl+C takes everyone off duty. Accounts are reused between runs (backend/.sim/).

Simulated people cannot hold up an ID card, so the script records a dev identity for them
straight in the local database (verified_by='simulator'), and sends a placeholder image as the
face scan when saying "I'm going" (accepted by FACE_CHECK_PROVIDER=mock only).
"""

import argparse
import asyncio
import base64
import json
import math
import os
import random  # GPS jitter only (not crypto)
import re
import sys
import time
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path

import httpx
import websockets
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

# Placeholder "face scan" for simulated responders: a JPEG header only. The mock face check
# accepts any real image type; it would (correctly) fail a real CompreFace match.
FACE_SCAN = ("scan.jpg", bytes([0xFF, 0xD8, 0xFF, 0xE0]) + bytes(64), "image/jpeg")

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # run from backend/ or anywhere

STATE = Path(__file__).resolve().parent.parent / ".sim" / "responders.json"
PROTOCOL = "sixthsense/live-location/v1"
AUDIO_PROTOCOL = "sixthsense/audio-clip/v1"
AUDIO_DIR = Path(__file__).resolve().parent.parent / ".sim" / "audio"
DEVICE_AUTH = "sixthsense-device-auth-v1"
WALK_MPS = 1.4

# name, bearing (deg from north), distance (m) from the centre
PEOPLE = [
    ("Riya", 0, 200),
    ("Kiran", 90, 350),
    ("Asha", 225, 450),
    ("Dev", 270, 800),  # asked when the radius grows to 1 km
    ("Meera", 180, 1600),  # asked when the radius grows to 2 km
]
# What each one does when asked: ("going", after_s) | ("decline", after_s) | ("ignore",)
SCENARIOS = {
    "normal": {
        "Riya": ("going", 8),
        "Kiran": ("going", 15),
        "Asha": ("decline", 10),
        "Dev": ("going", 10),
        "Meera": ("going", 10),
    },
    "slow": {
        "Riya": ("ignore",),
        "Kiran": ("ignore",),
        "Asha": ("decline", 20),
        "Dev": ("going", 10),
        "Meera": ("going", 12),
    },
    "far": {"Dev": ("going", 10), "Meera": ("going", 12)},
    "busy": {name: ("decline", 8 + i * 3) for i, (name, _, _) in enumerate(PEOPLE)},
}


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode()


def unb64url(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def raw(key) -> bytes:
    return key.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def offset(lat: float, lng: float, bearing: float, meters: float) -> tuple[float, float]:
    d = meters / 6_371_000
    b = math.radians(bearing)
    p1, l1 = math.radians(lat), math.radians(lng)
    p2 = math.asin(math.sin(p1) * math.cos(d) + math.cos(p1) * math.sin(d) * math.cos(b))
    l2 = l1 + math.atan2(
        math.sin(b) * math.sin(d) * math.cos(p1), math.cos(d) - math.sin(p1) * math.sin(p2)
    )
    return math.degrees(p2), math.degrees(l2)


def dist(a: tuple[float, float], b: tuple[float, float]) -> float:
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * 6_371_000 * math.asin(math.sqrt(h))


def header_bytes(session: str, sender: str, recipient: str, eph: str) -> bytes:
    # Same key order and compact form as Dart's jsonEncode in LiveLocationCipher.
    header = {
        "v": 1,
        "session_id": session,
        "sender_key_id": sender,
        "recipient_key_id": recipient,
        "ephemeral_public_key": eph,
    }
    return json.dumps(header, separators=(",", ":")).encode()


def encrypt(
    session, sender_key_id, signing: Ed25519PrivateKey, recipient_key_id, recipient_x: bytes, point
) -> dict:
    eph = X25519PrivateKey.generate()
    eph_pub = raw(eph.public_key())
    eph_b64 = b64url(eph_pub)
    head = header_bytes(session, sender_key_id, recipient_key_id, eph_b64)
    shared = eph.exchange(X25519PublicKey.from_public_bytes(recipient_x))
    key = HKDF(
        hashes.SHA256(), 32, salt=eph_pub, info=f"{PROTOCOL}|{session}|{recipient_key_id}".encode()
    ).derive(shared)
    nonce = os.urandom(12)
    sealed = AESGCM(key).encrypt(nonce, json.dumps(point, separators=(",", ":")).encode(), head)
    cipher, mac = sealed[:-16], sealed[-16:]
    signature = signing.sign(head + b"\x00" + nonce + cipher + mac)
    return {
        "v": 1,
        "session_id": session,
        "sender_key_id": sender_key_id,
        "recipient_key_id": recipient_key_id,
        "ephemeral_public_key": eph_b64,
        "nonce": b64url(nonce),
        "ciphertext": b64url(cipher),
        "mac": b64url(mac),
        "signature": b64url(signature),
    }


def decrypt(
    envelope: dict,
    my_key_id: str,
    agreement: X25519PrivateKey,
    sender_ed: bytes,
    protocol: str = PROTOCOL,
) -> dict | bytes:
    head = header_bytes(
        envelope["session_id"],
        envelope["sender_key_id"],
        my_key_id,
        envelope["ephemeral_public_key"],
    )
    nonce, cipher, mac = (unb64url(envelope[k]) for k in ("nonce", "ciphertext", "mac"))
    Ed25519PublicKey.from_public_bytes(sender_ed).verify(
        unb64url(envelope["signature"]), head + b"\x00" + nonce + cipher + mac
    )
    eph = unb64url(envelope["ephemeral_public_key"])
    shared = agreement.exchange(X25519PublicKey.from_public_bytes(eph))
    key = HKDF(
        hashes.SHA256(),
        32,
        salt=eph,
        info=f"{protocol}|{envelope['session_id']}|{my_key_id}".encode(),
    ).derive(shared)
    clear = AESGCM(key).decrypt(nonce, cipher + mac, head)
    return clear if protocol == AUDIO_PROTOCOL else json.loads(clear)


def save_audio_clip(bot_name: str, clear: bytes) -> Path:
    """An audio clip is [4-byte header length][JSON header][AAC]. Saved so you can play it."""
    length = int.from_bytes(clear[:4], "big")
    meta = json.loads(clear[4 : 4 + length])
    AUDIO_DIR.mkdir(parents=True, exist_ok=True)
    path = AUDIO_DIR / f"{bot_name}-{meta['kind']}-{meta['sequence']:04d}.aac"
    path.write_bytes(clear[4 + length :])
    return path


@dataclass
class Bot:
    name: str
    position: tuple[float, float]
    plan: tuple
    api: str
    speed: float
    state: dict = field(default_factory=dict)
    token: str = ""
    status: str = "starting"
    offer: dict | None = None
    owner_keys: list = field(default_factory=list)
    journey: str | None = None
    target: tuple[float, float] | None = None
    route: list = field(default_factory=list)
    route_for: tuple[float, float] | None = None
    arrived: bool = False
    seq: int = 0
    clips: int = 0

    # --- identity ------------------------------------------------------------------------

    @property
    def device_key(self) -> ec.EllipticCurvePrivateKey:
        return serialization.load_pem_private_key(self.state["device_pem"].encode(), None)

    @property
    def agreement(self) -> X25519PrivateKey:
        return X25519PrivateKey.from_private_bytes(base64.b64decode(self.state["x25519"]))

    @property
    def signing(self) -> Ed25519PrivateKey:
        return Ed25519PrivateKey.from_private_bytes(base64.b64decode(self.state["ed25519"]))

    def headers(self) -> dict:
        return {"Authorization": f"Bearer {self.token}"}

    def sign_up(self, http: httpx.Client, mail: str) -> None:
        email = f"sim-{self.name.lower()}-{uuid.uuid4().hex[:4]}@college.edu"
        key = ec.generate_private_key(ec.SECP256R1())
        public = b64(
            key.public_key().public_bytes(
                serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
            )
        )
        http.post(f"{self.api}/auth/otp/request", json={"email": email}).raise_for_status()
        code = None
        for _ in range(30):
            found = http.get(f"{mail}/api/v1/search", params={"query": f"to:{email}"}).json()[
                "messages"
            ]
            if found:
                text = http.get(f"{mail}/api/v1/message/{found[0]['ID']}").json()["Text"]
                code = re.search(r"\b(\d{6})\b", text).group(1)
                break
            time.sleep(0.5)
        if code is None:
            raise SystemExit(f"No sign-in code for {email} in Mailpit ({mail}).")
        session = http.post(
            f"{self.api}/auth/otp/verify",
            json={"email": email, "code": code, "device_public_key": public},
        ).json()
        self.token = session["access_token"]
        self.state.update(
            email=email,
            device_id=session["device_id"],
            account_id=session["account_id"],
            device_pem=key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            ).decode(),
            x25519=b64(os.urandom(32)),
            ed25519=b64(os.urandom(32)),
        )
        keys = http.put(
            f"{self.api}/auth/device/e2e-keys",
            headers=self.headers(),
            json={
                "x25519_public_key": b64(raw(self.agreement.public_key())),
                "ed25519_public_key": b64(raw(self.signing.public_key())),
            },
        ).json()
        self.state["key_id"] = keys["key_id"]
        self.ensure_verified(http)
        http.post(
            f"{self.api}/responders/apply", headers=self.headers(), json={"display_name": self.name}
        )

    def ensure_verified(self, http: httpx.Client) -> None:
        """Dev only: record a verified adult identity for this simulated person directly in the
        local database (a real person verifies with ID + selfie in the app)."""
        status = http.get(f"{self.api}/verification/me", headers=self.headers()).json()
        if status["status"] == "verified":
            return
        import hashlib

        from app.core.db import SessionLocal
        from app.verification.models import IdentityRecord

        account = uuid.UUID(self.state["account_id"])
        digest = hashlib.sha256(f"sixthsense-simulator:{account}".encode()).digest()
        now = datetime.now(UTC)
        with SessionLocal() as db:
            if db.get(IdentityRecord, account) is None:
                db.add(
                    IdentityRecord(
                        account_id=account,
                        id_type="simulator",
                        id_hmac=digest,
                        person_hmac=digest,
                        hmac_key_version=0,
                        is_adult=True,
                        verified_by="simulator",
                        verified_at=now,
                        valid_until=now + timedelta(days=365),
                    )
                )
                db.commit()

    def sign_in(self, http: httpx.Client) -> None:
        device = self.state["device_id"]
        nonce = http.post(f"{self.api}/auth/device/challenge", json={"device_id": device}).json()[
            "nonce"
        ]
        signature = self.device_key.sign(
            f"{DEVICE_AUTH}|{device}|{nonce}".encode(), ec.ECDSA(hashes.SHA256())
        )
        resp = http.post(
            f"{self.api}/auth/device/verify",
            json={"device_id": device, "nonce": nonce, "signature": b64(signature)},
        )
        resp.raise_for_status()
        self.token = resp.json()["access_token"]

    # --- walking ---------------------------------------------------------------------------

    async def fetch_route(self, http: httpx.AsyncClient) -> None:
        start, end = self.position, self.target
        url = (
            "https://routing.openstreetmap.de/routed-foot/route/v1/foot/"
            f"{start[1]},{start[0]};{end[1]},{end[0]}?overview=full&geometries=geojson"
        )
        try:
            data = (
                await http.get(url, headers={"User-Agent": "SixthSense-sim/0.1"}, timeout=10)
            ).json()
            coords = data["routes"][0]["geometry"]["coordinates"]
            # The street route ends on the nearest road; walk the last bit straight in.
            self.route = [(c[1], c[0]) for c in coords] + [end]
        except Exception:
            self.route = [end]  # straight line if the router is unreachable
        self.route_for = end

    def step(self, seconds: float) -> None:
        budget = WALK_MPS * self.speed * seconds
        while budget > 0 and self.route:
            nxt = self.route[0]
            gap = dist(self.position, nxt)
            if gap <= budget:
                self.position = nxt
                self.route.pop(0)
                budget -= gap
            else:
                f = budget / gap
                self.position = (
                    self.position[0] + (nxt[0] - self.position[0]) * f,
                    self.position[1] + (nxt[1] - self.position[1]) * f,
                )
                budget = 0

    def point(self) -> dict:
        self.seq = max(self.seq + 1, int(time.time() * 1000))
        jitter = random.uniform(-0.000015, 0.000015)  # noqa: S311
        return {
            "lat": self.position[0] + jitter,
            "lon": self.position[1] + jitter,
            "accuracy_m": round(random.uniform(4, 9), 1),  # noqa: S311
            "timestamp_ms": int(time.time() * 1000),
            "sequence": self.seq,
        }


async def run_bot(bot: Bot, args) -> None:
    async with httpx.AsyncClient(timeout=10) as http:
        last_presence = 0.0
        last_auth = time.time()
        asked_at = None
        ws = None
        while True:
            try:
                if time.time() - last_auth > 600:
                    await asyncio.to_thread(bot.sign_in, httpx.Client(timeout=10))
                    last_auth = time.time()
                    if ws:
                        await ws.close()
                        ws = None
                if time.time() - last_presence > 50:
                    await http.put(
                        f"{bot.api}/responders/presence",
                        headers=bot.headers(),
                        json={"latitude": bot.position[0], "longitude": bot.position[1]},
                    )
                    last_presence = time.time()

                offers = (
                    await http.get(f"{bot.api}/responders/offers", headers=bot.headers())
                ).json()["offers"]
                if not offers:
                    if bot.status == "declined":
                        pass  # a declined request disappears from my list; keep saying so
                    elif bot.offer is not None:
                        bot.status = "alert closed · back on duty"
                    elif not bot.status.startswith("alert closed"):
                        bot.status = "on duty · waiting"
                    bot.offer, bot.journey, bot.target, bot.arrived, asked_at = (
                        None,
                        None,
                        None,
                        False,
                        None,
                    )
                    if ws:
                        await ws.close()
                        ws = None
                    await asyncio.sleep(3)
                    continue

                offer = offers[0]
                if bot.offer is None or bot.offer["id"] != offer["id"]:
                    asked_at = time.time()
                    bot.status = f"ASKED · {offer['distance_m']} m away"
                bot.offer = offer
                action = bot.plan[0]

                if offer["status"] == "offered":
                    waited = time.time() - asked_at
                    if action == "ignore":
                        bot.status = f"asked {offer['distance_m']} m · not answering"
                    elif waited >= bot.plan[1]:
                        if action == "decline":
                            await http.post(
                                f"{bot.api}/responders/offers/{offer['id']}/decline",
                                headers=bot.headers(),
                            )
                            bot.status = "declined"
                        else:
                            resp = await http.post(
                                f"{bot.api}/responders/offers/{offer['id']}/going",
                                headers=bot.headers(),
                                files={"selfie_image": FACE_SCAN},
                            )
                            if resp.status_code == 409:
                                bot.status = "wanted to go · enough helpers already"
                                bot.plan = ("ignore",)
                            else:
                                body = resp.json()
                                bot.journey, bot.owner_keys = body["journey_id"], body["keys"]
                                bot.status = "GOING · waiting for their live location"
                    await asyncio.sleep(2)
                    continue

                # Going: listen for the traveller's location, walk there, share mine.
                if bot.journey is None:
                    body = (
                        await http.post(
                            f"{bot.api}/responders/offers/{offer['id']}/going",
                            headers=bot.headers(),
                            files={"selfie_image": FACE_SCAN},
                        )
                    ).json()
                    bot.journey, bot.owner_keys = body["journey_id"], body["keys"]
                if ws is None:
                    ws = await websockets.connect(args.api.replace("http", "ws", 1) + "/relay/ws")
                    await ws.send(json.dumps({"type": "auth", "access_token": bot.token}))
                await drain(ws, bot)
                if bot.target is None:
                    rough = offer.get("rough_area")
                    if rough:  # head for the rough area until the precise fix arrives
                        bot.target = (rough["latitude"], rough["longitude"])
                if bot.target is not None:
                    if bot.route_for is None or dist(bot.route_for, bot.target) > 40:
                        await bot.fetch_route(http)
                    bot.step(2)
                    left = dist(bot.position, bot.target)
                    if left < 30 and not bot.arrived:
                        await http.post(
                            f"{bot.api}/responders/offers/{offer['id']}/arrived",
                            headers=bot.headers(),
                        )
                        bot.arrived = True
                    bot.status = (
                        "ARRIVED · with them" if bot.arrived else f"GOING · {left:.0f} m to go"
                    )
                    envelopes = [
                        encrypt(
                            bot.journey,
                            bot.state["key_id"],
                            bot.signing,
                            k["key_id"],
                            base64.b64decode(k["x25519_public_key"]),
                            bot.point(),
                        )
                        for k in bot.owner_keys
                    ]
                    if envelopes:
                        await ws.send(json.dumps({"type": "location", "envelopes": envelopes}))
                await asyncio.sleep(2)
            except (httpx.HTTPError, OSError, websockets.WebSocketException) as error:
                bot.status = f"retrying ({type(error).__name__})"
                ws = None
                await asyncio.sleep(3)


async def drain(ws, bot: Bot) -> None:
    """Read whatever the relay sent; keep the traveller's latest precise location."""
    while True:
        try:
            frame = json.loads(await asyncio.wait_for(ws.recv(), timeout=0.05))
        except TimeoutError:
            return
        if frame.get("type") not in ("location", "audio"):
            continue
        envelope = frame["envelope"]
        if envelope["session_id"] != bot.journey:
            continue
        if frame["type"] == "audio":
            # Responders on their way hear the person after an SOS (end-to-end encrypted).
            try:
                clear = decrypt(
                    envelope,
                    bot.state["key_id"],
                    bot.agreement,
                    base64.b64decode(frame["sender"]["ed25519_public_key"]),
                    AUDIO_PROTOCOL,
                )
                save_audio_clip(bot.name, clear)
                bot.clips += 1
            except Exception:  # noqa: S112
                continue
            continue
        try:
            point = decrypt(
                envelope,
                bot.state["key_id"],
                bot.agreement,
                base64.b64decode(frame["sender"]["ed25519_public_key"]),
            )
            bot.target = (point["lat"], point["lon"])
        except Exception:  # noqa: S112  (bad or replayed envelope: skip it)
            continue


async def show(bots: list[Bot], centre) -> None:
    while True:
        lines = [
            "",
            f"Simulated responders (centre {centre[0]:.4f},{centre[1]:.4f}) · Ctrl+C = off duty",
        ]
        for bot in bots:
            away = dist(bot.position, centre)
            heard = f" · heard {bot.clips} audio clips" if bot.clips else ""
            lines.append(f"  {bot.name:6} {away:5.0f} m from centre · {bot.status}{heard}")
        print("\n".join(lines), flush=True)
        await asyncio.sleep(5)


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("--scenario", choices=sorted(SCENARIOS), default="normal")
    parser.add_argument(
        "--center", default="12.8907,77.5827", help="lat,lng (default Brigade Millennium)"
    )
    parser.add_argument("--speed", type=float, default=3.0, help="x normal walking speed")
    parser.add_argument("--api", default="http://localhost:8000")
    parser.add_argument("--mail", default="http://localhost:8025")
    args = parser.parse_args()
    centre = tuple(float(x) for x in args.center.split(","))
    plan = SCENARIOS[args.scenario]

    saved = json.loads(STATE.read_text()) if STATE.exists() else {}
    bots: list[Bot] = []
    with httpx.Client(timeout=10) as http:
        for name, bearing, meters in PEOPLE:
            if name not in plan:
                continue
            bot = Bot(
                name,
                offset(*centre, bearing, meters),
                plan[name],
                args.api,
                args.speed,
                saved.get(name, {}),
            )
            if bot.state:
                try:
                    bot.sign_in(http)
                    bot.ensure_verified(http)
                except httpx.HTTPError:
                    bot.state = {}
            if not bot.state:
                print(f"Signing up {name}…", flush=True)
                bot.sign_up(http, args.mail)
            saved[name] = bot.state
            bots.append(bot)
    STATE.parent.mkdir(exist_ok=True)
    STATE.write_text(json.dumps(saved, indent=1))
    print(
        f"Scenario '{args.scenario}': " + ", ".join(f"{b.name} {b.plan[0]}" for b in bots),
        flush=True,
    )

    async def everything():
        await asyncio.gather(show(bots, centre), *(run_bot(b, args) for b in bots))

    try:
        asyncio.run(everything())
    except KeyboardInterrupt:
        with httpx.Client(timeout=5) as http:
            for bot in bots:
                http.delete(f"{args.api}/responders/presence", headers=bot.headers())
        print("\nEveryone is off duty.")


if __name__ == "__main__":
    main()
