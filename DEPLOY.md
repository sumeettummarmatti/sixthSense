# Deploying SixthSense

This puts the Core API, the alert worker, the Insight API, both databases, Redis, NATS and the
self-hosted face matcher (CompreFace) on one Linux server behind HTTPS, and builds the Android
app pointed at it. Allow about an hour the first time.

## 1. Server

| | Recommended |
|---|---|
| OS | **Ubuntu 24.04 LTS x64** |
| Size | **4 vCPU / 8–16 GB RAM**, 80 GB+ disk (CompreFace alone needs ~2.5 GB RAM) |
| CPU | **x86-64 (Intel/AMD)**: CompreFace does not run on ARM servers |
| Login | SSH key, password login off |

**Firewall** (in the cloud provider's panel): allow inbound **TCP 22, 80, 443 only**. Docker
publishes ports past the server's own firewall, so the provider firewall matters; the installer
also binds every container to localhost.

## 2. Domains

Point two hostnames at the server's IP, for example `api.example.com` and
`insight.example.com` (A records). No domain yet? `sslip.io` works with no setup:
for IP `203.0.113.7` use `api.203-0-113-7.sslip.io` and `insight.203-0-113-7.sslip.io`.

## 3. Install (one command)

```bash
ssh root@SERVER_IP
apt-get update && apt-get install -y git
git clone https://github.com/<you>/<repo>.git /opt/sixthsense
cd /opt/sixthsense
bash deploy/install.sh api.example.com insight.example.com
```

The installer:
1. installs Docker, Caddy and uv, and opens 80/443 in `ufw` if it is active;
2. writes `.env` with fresh random secrets (`deploy/make_env.py`) and prints the admin password;
3. starts the databases, Redis, NATS and CompreFace on localhost only;
4. creates the CompreFace face-verification service and saves its key (`deploy/setup_compreface.sh`);
5. installs Python dependencies and creates all tables (Alembic);
6. starts `sixthsense-core`, `sixthsense-worker` and `sixthsense-insight` as systemd services;
7. sets up HTTPS with Caddy and checks `https://<domain>/healthz`.

**Keep `.env` safe and never commit it.** Changing `OTP_PEPPER`, `FACE_TEMPLATE_KEY` or
`IDENTITY_HMAC_SECRET` later makes existing accounts, face references or ID checks unusable.

## 4. Email and Telegram (needed for real users)

Edit `/opt/sixthsense/.env`, then run `systemctl restart sixthsense-core sixthsense-worker`.

- **Sign-in codes by email.** Use a Gmail account with 2-Step Verification and an App password
  (myaccount.google.com/apppasswords):
  ```
  SMTP_HOST=smtp.gmail.com
  SMTP_PORT=587
  SMTP_USERNAME=you@gmail.com
  SMTP_PASSWORD=<16-letter app password, no spaces>
  SMTP_STARTTLS=true
  SMTP_SSL=false
  SMTP_FROM=SixthSense <you@gmail.com>
  ```
  Test it: `cd backend && uv run --no-dev python scripts/send_test_email.py you@example.com`
- **Alerts on Telegram.** Create a bot with @BotFather and set `TELEGRAM_BOT_TOKEN` and
  `TELEGRAM_BOT_USERNAME`. Only one server may use a bot token at a time (it polls for messages).

## 5. Android app

On a computer with Flutter and the Android SDK:

```bash
cd mobile
flutter build apk --release --split-per-abi \
  --dart-define=API_BASE_URL=https://api.example.com \
  --dart-define=INSIGHT_BASE_URL=https://insight.example.com
```

Install `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` on phones
(`app-armeabi-v7a-release.apk` for very old ones). Release builds require HTTPS.
For the Play Store, add your own signing key in `mobile/android/app/build.gradle.kts`
(it currently signs with the debug key).

## 6. Admin

`https://api.example.com/admin/feedback` (user `admin`, password from `.env`): every rating,
CSV downloads, and helpers suspended by a 1-star rating waiting for **Ban** or **Restore**.

Command-line tools (run in `/opt/sixthsense/backend` with `uv run --no-dev python`):
`scripts/feedback.py`, `scripts/responders.py`, `scripts/companions.py`.

## 7. Day to day

| Task | Command |
|---|---|
| Status | `systemctl status sixthsense-core sixthsense-worker sixthsense-insight` |
| Logs | `journalctl -u sixthsense-core -f` |
| Update | `cd /opt/sixthsense && git pull && (cd backend && uv sync --no-dev && uv run --no-dev alembic upgrade head) && (cd insight && uv sync --no-dev && uv run --no-dev alembic upgrade head) && systemctl restart sixthsense-core sixthsense-worker sixthsense-insight` |
| Containers | `docker compose --env-file .env -f infra/docker-compose.yml -f deploy/docker-compose.server.yml ps` |
| Back up the databases | `docker exec sixthsense-core-db-1 pg_dump -U core sixthsense_core > core.sql` (same for `insight-db`) |

## Settings worth knowing (`.env`)

| Setting | Meaning |
|---|---|
| `FACE_CHECK_PROVIDER=auto` | Face scan before sharing location: matched against the saved face reference when there is one |
| `PUBLISH_MIN_REPORTS` / `PUBLISH_MIN_DEVICES` | How many reports, from how many people, before a place affects routes (5 / 3) |
| `ROUTES_AREA_FILE` | Area with route data; build another with `insight/scripts/build_area_features.py` |
| `ROUTING_PROVIDER` | `osrm` (free public server) or `valhalla` (self-hosted, see `routing-engine/`) |
