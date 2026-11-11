# SixthSense — Progress Log

> Human-readable session log (newest at top). Machine state lives in `progress.json`.
> **Every entry heading names its author:** `## <date> — sumeet: ...` (or `tanisha:`, `shruj:`, `jival:`).

## Status at a glance (updated 2026-11-11)

**Phase:** M0 Setup → next **M1 Foundation** (weeks 1–2: sign up + add contacts)
**Platform:** Android first; iOS later.

| Lane | Done | Up next |
|---|---|---|
| ALL | Planner, progress tracking, colour system | `ALL-W1-api-contract`: agree on `contracts/openapi.yaml` together |
| P1 Mobile (**tanisha**) | Flutter shell + theme; Android toolchain ready; sign-up + contacts UI; journey UI + local timer; SOS + duress PIN flow; Android SOS shortcuts; offline SMS and low-battery routing; foreground service + exact alarms; W6 crypto client; W7 walk screens; W9 map/report privacy client | W6 integration awaits P2 identity/contact-key APIs and ciphertext relay; physical USB, battery, carrier-SMS, camera, and map checks remain pending |
| P2 Safety Core | Repo, backend skeleton, local databases running + migrated | `P2-W1-otp-device-auth` |
| P3 Trust | — | `P3-W1-vendor-selection` (KYC + liveness sandboxes) |
| P4 Insight | Insight service skeleton, dashboard shell | `P4-W1-report-model-separate-db` |

**Budget:** ₹0, free tools only (`PLANNER.md` §3b).
**Blockers:** Android download timeout on Sumeet’s Mac (Gradle wrapper was fixed manually); need a Xiaomi/Oppo/Vivo/Samsung test phone · legal review (DPDP, UIDAI) · campus MoU.
**Lane owners:** P1 = tanisha. sumeet, shruj, jival: lanes not assigned yet (`progress.json` → `team` and `lanes.P*.owner`).

## 2026-11-11 — Tan: P1 map, route preview, and anonymous report privacy
- Tan: Added a MapLibre/OpenFreeMap map screen with an explicit **Insufficient data** state and no route recommendation until P4 routing/risk data is available. Location permission is requested only when the user asks to center the map.
- Tan: Added a category-only report form and on-device planar-Laplace location noise (100 m expected radial offset) plus two-hour local time buckets. The preview payload contains only the noisy point, category, and time bucket; no report is uploaded while the P4 endpoint is unavailable.
- Tan: `flutter analyze`, all 10 tests, `flutter build apk --debug`, `git diff --check`, `progress.json` parsing, and iOS plist validation pass. Manual map/location preview steps are in `mobile/README.md`.

## 2026-11-11 — Tan: P1 Walk With Me screens
- Tan: Added traveller and companion preview flows, public meeting-point selection, sample profile, four-digit handshake screen, local masked chat with phone-number rejection, companion duty toggle, pose prompt, and camera selfie capture. Android blocks screenshots throughout the Walk With Me flow.
- Tan: Camera bytes stay in memory and the temporary image is deleted after reading. Ending the demo clears chat/selfie from memory and removes profile/route from the completion view.
- Tan: `flutter analyze`, all 7 tests, and `flutter build apk --debug` pass. Manual flow steps are in `mobile/README.md`. Real matching, shared handshake verification, remote masked chat, and liveness detection remain P3 service work; the screens clearly identify the demo limitations.

## 2026-11-11 — Tan: P1 end-to-end location encryption client
- Tan: Added a versioned, per-recipient location envelope using X25519, HKDF-SHA256, AES-256-GCM, and Ed25519 signatures. Coordinates, accuracy, timestamp, and sequence remain encrypted; decryption verifies signature, session/recipient binding, authentication tag, and replay watermark.
- Tan: Added round-trip, ciphertext-metadata, tampering, context-binding, and replay tests. `flutter analyze`, all 5 widget/crypto tests, and `flutter build apk --debug` pass.
- Tan: Live GPS publishing and relay are not connected: authenticated device-key provisioning, trusted-contact public-key lookup, and the ciphertext WebSocket relay are P2 dependencies still open. W6 stays in progress until those integrations are available.

## 2026-11-11 — Tan: P1 offline SMS and low-battery mode
- Tan: Added an opt-in journey SMS contact, runtime SMS/location permissions, and Android Keystore encryption for that contact until the journey ends.
- Tan: Offline SOS, covert SOS/duress, and missed check-ins submit SMS with a Maps link when a fresh last-known location is available. At 10% battery or lower, the app submits one low-battery SMS and routes later journey alerts through SMS.
- Tan: Documented carrier and low-battery manual checks in `mobile/README.md`; physical SIM checks were not run. `flutter analyze`, `flutter test` (2 tests), `flutter build apk --debug`, and `git diff --check` pass.

## 2026-11-11 — Tan: P1 Android SOS shortcuts
- Tan: Added the foreground Volume Up → Volume Down → Volume Up pattern, a user-added Quick Settings SOS tile, and a home-screen SOS widget. Each routes to the same local SOS notification; no contact or emergency alert is sent.
- Tan: Documented shortcut setup, test steps, foreground-only volume detection, and the placeholder onboarding behavior (no OTP is sent or verified; contacts can be skipped).
- Tan: `flutter analyze`, `flutter test` (2 tests), and `flutter build apk --debug` pass. Manual tile/widget/volume checks are listed in `mobile/README.md`.

## 2026-11-11 — Tan: Updated P1 status for Android-first plan
- Tan: Synced the task branch with the latest Android-first plan and updated P1’s next tasks and blockers.

## 2026-11-11 — Tan: P1 Android journey emulator check
- Tan: Tanisha manually tested the journey timer flow on the emulator and reported it is working well so far.
- Tan: Physical USB-device and vendor battery-saver checks remain deferred.

## 2026-11-11 — Tan: P1 Android journey service and alarms
- Tan: Added an Android foreground service with a private ongoing notification and exact, allow-while-idle check-in alarms; check-in resets the alarm and ending a journey cancels it.
- Tan: Added notification and exact-alarm permission handling, an optional battery-optimization exemption action, and alarm rescheduling after device reboot. Android stores only the active flag and next deadline; destination and PINs are not persisted.
- Tan: Made the countdown content scale down on compact screens and kept the prototype limitation clear: missed check-ins do not alert contacts, and SOS/duress do not send alerts yet.
- Tan: Added manual emulator verification steps to `mobile/README.md`. `flutter analyze`, `flutter test`, and `flutter run -d emulator-5554` pass; Tanisha later reported the emulator timer flow is working well so far. Physical-device checks were deferred at Tanisha’s request.

## 2026-11-11 — Tan: P1 Android emulator run
- Tan: Started `Medium_Phone_API_37.0` directly after Flutter's emulator launcher failed to register it with ADB.
- Tan: Built, installed, and launched the Flutter app on `emulator-5554`; confirmed the app process is running. The first Android build installed NDK 28.2.13676358 and Android SDK Platform 36.
- Tan: The physical Android phone USB-debugging check remains open, so `P1-W0-android-device` is in progress.

## 2026-11-11 — Tan: Updated P1 status for Android-first plan
- Tan: Synced the task branch with the latest Android-first plan and updated P1’s next tasks and blockers.
- Tan: `flutter doctor` confirms Flutter and Android SDK 36.0.0 are ready.

## 2026-11-11 — Tan: Reconciled progress during upstream pull
- Tan: Kept the latest upstream Android-first setup notes and reconciled the P1 work log during the rebase.
- Tan: Tried to launch `Medium_Phone_API_37.0`; Flutter and ADB did not detect a running Android device, so app-on-emulator verification remains open.

## 2026-11-11 — Tan: P1 SOS and duress PIN
- Tan: Added an SOS action with a clear prototype limitation message, a hidden long-press gesture on the lamp icon for covert SOS, and separate check-in/duress PINs. Three wrong PINs trigger the silent coercion handler.
- Tan: Both PINs use the same obscured entry screen. PINs remain in memory only; SOS/duress do not contact anyone yet. Android volume-button, Quick Settings, and widget triggers are tracked separately.
- Tan: `flutter analyze` passes and both widget tests pass, covering timer due/reset, normal and duress PIN handling, SOS, and covert SOS.

## 2026-11-11 — Tan: P1 journey screens and on-device timer
- Tan: Added journey setup (destination and check-in interval), active countdown, check-in due state, and timer reset on check-in; the countdown is local to the phone.
- Tan: The timer refreshes when the app returns to foreground. Android foreground service/exact alarms, escalation, and persistence across app termination remain open.
- Tan: `flutter analyze` passes and both widget tests pass, including the countdown-to-due and check-in-reset flow.

## 2026-11-11 — Tan: P1 Flutter toolchain check
- Tan: Reran `flutter doctor` after the platform plan changed: Flutter 3.47.9 and Android SDK 36.0.0 pass; Xcode and the iOS simulator remain installed for the later iOS port.

## 2026-11-11 — Tan: P1 sign-up and contacts UI
- Tan: Added a phone-number entry screen, verification-code screen, and trusted contacts screen with add/remove flows and privacy guidance.
- Tan: This is a local UI flow; OTP delivery and contact persistence await the shared API contract and P2 endpoints.
- Tan: Next, connect the screens after `ALL-W1-api-contract`; Flutter toolchain setup is now complete.

---

## 2026-11-11 — sumeet: Android toolchain ready
- `flutter doctor` shows Android ✓; emulator `Medium_Phone_API_37.0` boots.
- The first build's Gradle download timed out from Java (network quirk on Sumeet's Mac), so I downloaded it manually and verified it. README troubleshooting now has the fix.
- **Next:** finish the first build, run the app on the emulator; teammates run the setup check (README → Check everything works).

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
