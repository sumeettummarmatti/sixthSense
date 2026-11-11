# SixthSense — Progress Log

> Human-readable session log (newest at top). Machine state lives in `progress.json`.
> **Every entry heading names its author:** `## <date> — sumeet: ...` (or `tanisha:`, `shruj:`, `jival:`).

## Status at a glance (updated 2026-11-11)

**Phase:** M0 Setup → next **M1 Foundation** (weeks 1–2: sign up + add contacts)
**Platform:** Android first; iOS later.

| Lane | Done | Up next |
|---|---|---|
| ALL | Planner, progress tracking, colour system | `ALL-W1-api-contract`: agree on `contracts/openapi.yaml` together |
| P1 Mobile (**tanisha**) | Flutter shell + theme | Finish Android toolchain, run on emulator → `P1-W0-android-device` → `P1-W1-signup-contacts-ui` |
| P2 Safety Core | Repo, backend skeleton, local databases running + migrated | `P2-W1-otp-device-auth` |
| P3 Trust | — | `P3-W1-vendor-selection` (KYC + liveness sandboxes) |
| P4 Insight | Insight service skeleton, dashboard shell | `P4-W1-report-model-separate-db` |

**Budget:** ₹0, free tools only (`PLANNER.md` §3b).
**Blockers:** Android Command-line Tools + licenses · need a Xiaomi/Oppo/Vivo/Samsung test phone · legal review (DPDP, UIDAI) · campus MoU.
**Lane owners:** P1 = tanisha. sumeet, shruj, jival: lanes not assigned yet (`progress.json` → `team` and `lanes.P*.owner`).

---

## 2026-11-11 — sumeet: Android first (replaces iOS only)
- **We now build for Android first; iOS comes later** (`P1-LATER-ios-port`). `mobile/ios/` stays in the repo but isn't built for now.
- **Why:** it's free to share the app (APK) with any number of testers, and most of our users have Android phones. Android also allows what the docs need: the phone sends SMS by itself when offline, a background journey timer (foreground service), button SOS, screenshot blocking (`FLAG_SECURE`) and free push (FCM).
- **Budget is still ₹0.** Alerts go out as FCM push → Telegram → email, plus SMS from the user's own phone plan. The app is shared as an APK, with no Play Store or Apple account.
- **P1 task changes:**
  - `P1-W0-ios-signing` → `P1-W0-android-device`
  - `P1-W3-ios-background-checkins` → `P1-W3-android-foreground-service`
  - `P1-W4-ios-sos-shortcuts` → `P1-W4-android-sos-triggers`
- **README:** step 3 is the Android setup again; Xcode isn't needed.
- **Next:** tanisha ticks Command-line Tools in Android Studio, accepts the licenses, creates an emulator and runs the app.

## 2026-11-11 — sumeet: Zero-cost plan
- **Budget is ₹0.** Every paid service in the docs now has a free substitute (`PLANNER.md` §3b):
  - free Apple ID signing instead of the $99 account
  - Telegram bot + email alerts instead of paid SMS/voice and APNs
  - email OTP instead of SMS OTP
  - college-email + security sign-off verification instead of paid KYC
  - Apple Vision face check
  - OpenFreeMap tiles
  - Oracle Always Free hosting
  - in-house security testing
- `P3-W3-tier1-verification` (Aadhaar KYC) is deferred: it needs a paid vendor.
- **Trade-off:** free iOS signing means 7-day app expiry and max 3 devices, so the free pilot is small. A wider pilot needs a sponsor for the $99 account, or Android.

## 2026-11-11 — sumeet: iOS only, name-tagged updates, Tanisha on P1
- **iOS only for now; Android later** (`P1-LATER-android-port`). `mobile/android/` stays in the repo but isn't built or tested.
- iOS limits and our workarounds are in `PLANNER.md` §3a: server watchdog SMS + pre-filled SMS / one-tap 112 instead of silent SMS; App Intents (Action Button, Back Tap, Siri) for covert SOS; local-notification check-ins; screenshot detection.
- New P1 tasks: `P1-W0-ios-signing`, `P1-W3-ios-background-checkins`, `P1-W4-ios-sos-shortcuts`. README setup is now iOS only.
- **Tanisha owns P1 Mobile.** Every update is now tagged `sumeet:` / `tanisha:` / `shruj:` / `jival:` (task notes, decisions, these headings).
- **Next:** tanisha finishes the iOS toolchain and runs the app on the simulator; decide on the Apple Developer account.

## 2026-11-11 — sumeet: README setup guide
- Rewrote README as a step-by-step "set up from scratch" guide (Homebrew → tools → mobile toolchain → clone → deps → databases), plus daily run commands, a check-everything block and a troubleshooting table.
- Tested step 6 end to end: all 4 services healthy, migrations applied on both databases, both APIs answer `/healthz` and `/docs`.
- Fixes found by testing: core database moved to port **5434** (5432 clashes with a local Postgres); `alembic.ini` needed `prepend_sys_path = .`.

## 2026-11-11 — sumeet: CI removed
- Removed the CI workflow and Dependabot at Sumeet's request; CI/CD will be set up later. Run checks locally (README → Check your setup).

## 2026-11-11 — sumeet: Team handoff
- Added `CLAUDE.md` (auto-loaded project context for Claude Code), a README team guide with example prompts, and the status table above.
- README: added "Check your setup" (tool versions, flutter doctor, project checks).
- Pushed `setup/foundation` (commits authored by Sumeet only) and opened PR #1: https://github.com/sumeettummarmatti/sixthSense/pull/1

## 2026-11-11 — sumeet: Colour system
- "Lamplight Lavender" palette sampled from the logo; preview: https://claude.ai/artifact/5KNxV34PQeqNBWBQMXM6Xz
- Applied to Flutter (`mobile/lib/core/theme/app_theme.dart`, light + night ColorScheme) and dashboard (`globals.css` tokens, colour-coded evidence legend).
- Rules: no green, red only for SOS / strong evidence, same colours on real and duress PIN screens.
- Still open: Android cmdline-tools, Xcode first launch, OK to start Docker.

## 2026-11-11 — sumeet: M0 setup (branch `setup/foundation`)
- **Done:** repo root files, `infra/docker-compose.yml` (2× PostGIS on separate networks, Redis, NATS), `backend/` (10 module routers, PII-scrubbing logs, Alembic; 11 tests), `insight/` (own DB only, no-"safe" labels, k/m threshold, isolation tests; 14 tests), `dashboard/` (Next.js + MapLibre; build passes), `routing-engine/` Valhalla stub, `contracts/openapi.yaml` skeleton, CI + Dependabot.
- **Fixed along the way:** phone-number regex missed a leading `0`; pnpm 12 via corepack is broken here, so pnpm is pinned to 10.18.0.
- **Waiting on:** Flutter + Android Studio install; OK to start Docker containers.
- **Next:** Flutter shell in `mobile/`, bring up DBs and run migrations, push + PR, then the week-1 API contract.

## 2026-11-11 — sumeet: Planning
- Synced local `main` with GitHub (`915c986`).
- Read all three design docs + logo. Wrote `PLANNER.md` (features, architecture, stack, P1–P4 lanes, 12-week task IDs, open items).
- Created `progress.json` (source of truth) and this log.
- **Decisions:** code name `sixthsense`; 4-person lanes; local-first setup; JSON + MD tracking.
- **Blockers:** Flutter not installed; legal review + campus MoU pending.
- Evaluated **xtool** (cross-platform Xcode replacement for SwiftPM iOS apps): not adopting — it can't build Flutter apps, and Xcode 26.4.1 is already installed. Android SDK still needed for Flutter Android.
- **Next:** start M0 setup on branch `setup/foundation` — monorepo, Docker Compose (2× PostGIS, Redis, NATS), FastAPI backend + insight skeletons, Next.js dashboard, Flutter shell, CI.
