# SixthSense — Progress Log

> Human-readable session log (newest at top). Machine state lives in `progress.json`.
> **Every entry heading names its author:** `## <date> — sumeet: ...` (or `tanisha:`, `shruj:`, `jival:`).

## Status at a glance (updated 2026-11-11)

**Phase:** **2-day demo** from branch `demo` (12-week plan paused; see `PLANNER.md` §0)
**Platform:** Android first; iOS later.

| Lane | Done | Up next |
|---|---|---|
| ALL | Planner, progress tracking, colour system | `ALL-W1-api-contract`: agree on `contracts/openapi.yaml` together |
| P1 Mobile (**tanisha**) | Flutter shell + theme; Android toolchain ready; sign-up + contacts UI; journey UI + local timer; SOS + duress PIN flow; Android SOS shortcuts; offline SMS and low-battery routing; foreground service + exact alarms; W6 crypto client; W7 walk screens; W9 map/report privacy client | W6 integration awaits P2 identity/contact-key APIs and ciphertext relay; physical USB, battery, carrier-SMS, camera, and map checks remain pending |
| P2 Safety Core (**shruj**) | Repo, backend skeleton, local databases running + migrated; **email-code sign-in + device-bound keys** (`P2-W1`); **trusted contacts** (`P2-W2`); **journey state machine** (`P2-W3`); **watchdog + alert ladder** (`P2-W4`); **encrypted location relay** (`P2-W5`); **signed alerts** (`P2-W6`); **demo: real Telegram alerts proven** (`P2-W1-demo-telegram-live`) | Help Tanisha wire the app (`P1-W1-demo-api-wiring`); merge `p2/demo-telegram-live` into `demo` |
| P3 Trust | — | `P3-W1-vendor-selection` (KYC + liveness sandboxes) |
| P4 Insight | Insight service skeleton, dashboard shell | `P4-W1-report-model-separate-db` |

**Budget:** ₹0, free tools only (`PLANNER.md` §3b).
**Blockers:** need a Xiaomi/Oppo/Vivo/Samsung test phone · legal review (DPDP, UIDAI) · campus MoU.
**Lane owners:** P1 = tanisha, P2 = shruj. For the demo: sumeet = server + Telegram bot, jival = script + slides. P3/P4 unassigned.

## 2026-11-12 — sumeet: 2-phone run passed; live location + new home
- 2-phone run passed on emulators over ZeroTier: sign-up, invite, Telegram link, SOS alert with matching code, resolve, missed check-in.
- Fixed on the way: worker crash on slow Wi-Fi (PR #4), signed-in POSTs never sent (PR #5), SOS 'no_server_journey' after a failed start + silent bare /start (PR #6), journey-over after a contact resolves.
- New: precise live location to contacts during a journey, end-to-end encrypted over the relay (server stores nothing); map with accuracy on the contact's alert card.
- New: home tabs Journey / My people / I support; add and remove contacts any time (names stay on the phone).
- Next: test live location with Shruj, UI polish, SIM phone test, slides.

## 2026-11-12 — sumeet: demo server over ZeroTier
- Joined Shruj's ZeroTier network (8d1c312afad78cd4); left the other one. Laptop = 10.41.90.84.
- API runs on the laptop at http://10.41.90.84:8000; sign-up codes at http://10.41.90.84:8025 (Mailpit). `.env` PUBLIC_BASE_URL points there, so Telegram "I'm on it" links work on any ZeroTier device.
- Demo APK built with `--dart-define=API_BASE_URL=http://10.41.90.84:8000` (~/Desktop/sixthsense-demo/).
- Fixed worker crash: the 5-second tick blocked the event loop (Telegram call ~1.8 s on our Wi-Fi), so arq's Redis connect timed out after 1 s and the worker died. Tick now runs in a thread; Redis connect timeout 5 s. Branch p2/worker-nonblocking-tick.
- Next: Shruj stops her worker, sumeet starts it; 2-phone run; SIM phone offline/reboot test; jival slides; rehearse.

## 2026-11-12 — sumeet: Contact alert screen (on Tanisha's behalf)
- sumeet: `main` now has everything (PR #2 merged; PR #1 counted as merged). Everyone branches off `main` from now on.
- sumeet: New **People you support** screen (heart icon on *Plan a journey*): open alerts where you are a trusted contact, with the **verification code** to compare against the Telegram message, and **I'm on it** / **I've reached them, they're OK** / **I can't reach them, raise the alarm** (the last only for a missed check-in). Silent alarms say *don't call them*. Red only for full alerts.
- sumeet: A **banner on the home screen** appears within ~10 s when someone needs you; tap it to respond.
- sumeet: Checks: `flutter analyze` clean, 16 Flutter tests (3 new). Live: SOS -> contact sees it (code shown) -> ack 200 -> resolve 200 -> no open alerts.

## 2026-11-12 — sumeet: Offline safety fixes (on Tanisha's behalf, branch `p1/demo-offline-fixes`)
- sumeet: **Missed check-in no longer texts straight away.** At the deadline the phone shows the private "check-in due" prompt; only if she still hasn't checked in 4 minutes later (server's grace 2 min + prompt 2 min) does it send the offline SMS. Checking in cancels it. A stale alarm can't fire after a check-in (it checks the deadline it was set for).
- sumeet: **After a reboot** the journey service comes back (not just the alarm), with the saved SMS setting kept. If the check-in time passed while the phone was off, it prompts right away and texts 2 minutes later if she doesn't check in.
- sumeet: **Low-battery SMS** no longer counts as sent when it failed; it retries every 2 minutes until it goes out. Checking in no longer resets low-battery mode.
- sumeet: If exact alarms get revoked, the escalation still fires (inexact alarm) rather than being skipped.
- sumeet: Checks: debug APK builds (Kotlin compiles), `flutter analyze` clean, 13 Flutter tests, 185 backend tests. **Not yet tested on a real phone with a SIM** (must-do list).

## 2026-11-12 — sumeet: Accept invite in the app (on Tanisha's behalf)
- sumeet: The contact's phone can now become a contact: **"I got an invite link"** in setup, and a link icon on the *Plan a journey* screen. Paste the invite link; the app sends the part after `#` to `POST /contacts/invites/accept`, then offers **Get alerts on Telegram**. A Telegram icon sits next to it for later.
- sumeet: The invite now carries the owner's email prefix as their name (was "SixthSense user"), so the contact knows who invited them.
- sumeet: New `mobile/lib/features/contacts/contact_alerts.dart` (accept + Telegram flows, shared by both screens).
- sumeet: Checks: `flutter analyze` clean, 13 tests pass (2 new: token parsing, paste-and-accept flow). Live run against the API: accept 200, owner sees the contact as accepted, contact gets a Telegram link.
- sumeet: Next: full 2-phone run with API + worker on one laptop.

## 2026-11-12 — sumeet: Merged everyone's demo work into `demo`
- sumeet: `demo` now has Tanisha's app wiring (email sign-in + device key, add contact invite, "Get alerts on Telegram", journey/heartbeat/check-in/SOS/end), Shruj's real Telegram alerts (`p2/demo-telegram-live`) and the optional real-email setup (`p2/demo-real-email`, parked; Mailpit for now).
- sumeet: Fixed a test that failed on any machine whose `.env` has real secrets (it now ignores `.env`).
- sumeet: Checks: backend ruff clean, 185 tests pass; `flutter analyze` clean, 11 tests pass.
- sumeet: **Gap:** the app can't accept an invite yet (`POST /contacts/invites/accept`). Telegram alerts only go to contacts who accepted, so this is needed for the 2-phone demo.

## 2026-11-11 — sumeet: Real email for sign-in codes (branch p2/demo-real-email)
- sumeet: New branch `p2/demo-real-email` on top of Shruj's `p2/demo-telegram-live`. Goal: sign-in codes reach real inboxes for the demo, not Mailpit.
- sumeet: Shruj's mailer already spoke plain SMTP. Added: **verified TLS** (smtplib's default skips certificate checks), an `SMTP_SSL` option for port 465, and `backend/scripts/send_test_email.py <address>`, which sends one test email and explains common errors.
- sumeet: `.env.example` now has a step-by-step Gmail App password block. Mailpit stays the default for development, so Tanisha and Shruj need no change.
- sumeet: Note: Shruj's `scripts/demo_telegram_check.py` reads codes from Mailpit, so start the API with `SMTP_HOST=localhost SMTP_PORT=1025 SMTP_STARTTLS=false` when running it.
- sumeet: Checks: ruff clean, 185 tests pass (3 new mailer tests: verified STARTTLS, implicit SSL, failure logs only the error type).
- sumeet: Next: put the team Gmail + App password in `.env` and send one real test email.

## 2026-11-11 — shruj: Real Telegram alerts work (demo)
- shruj: `P2-W1-demo-telegram-live` **done.** With Sumeet's bot (`@Sixtysensebot`) in my `.env` (not in git), a real Telegram alert reached a contact's phone for **both** demo cases:
  - **SOS:** "URGENT: Priya may need help now" arrived 4 s after the SOS, with a verification code that matched the app.
  - **Missed check-in:** "Priya missed a safety check-in" arrived 126 s after starting a journey with demo timers (1-min check-in, no grace, 1-min prompt), then "All clear" when she checked in.
- shruj: Repeatable check for rehearsals: `cd backend && uv run python scripts/demo_telegram_check.py` (API + worker running). It prints a Telegram link; press Start and it runs both cases.
- shruj: **Fixed (found while testing):**
  - On our Wi-Fi, opening a connection to Telegram takes ~8 s and sometimes gets reset. The Telegram sender now waits up to 20 s to connect and retries 3 times. It only retries when connecting fails, so nobody gets the same alert twice.
  - The contact who taps "They're safe" was also sent "All clear: another trusted contact confirmed…". Now only the other contacts get it.
  - Stray spaces in the token, or an `@` in the bot username in `.env`, no longer break things.
  - Tests now use their own database (`sixthsense_core_test`, made automatically) and never use real Telegram/Firebase keys from `.env`. Old test data in the dev database was making tests fail.
- shruj: **For the demo (Sumeet):** only ONE laptop may run the worker with the bot token, or the two steal each other's Telegram messages and "Start" links fail. Set `PUBLIC_BASE_URL` to the laptop's Wi-Fi IP (e.g. `http://192.168.1.9:8000`) or the tunnel URL, or the "I'm on it" links in alerts won't open on phones. Start the API with `--host 0.0.0.0` so phones on the Wi-Fi can reach it. Use short demo timers via `PUT /journeys/protocol` for the missed check-in.
- shruj: Checks: ruff clean, 182 tests pass. Branch `p2/demo-telegram-live` (from `demo`); merge it into `demo`.
- **Next:** help Tanisha when her app calls fail (`P1-W1-demo-api-wiring`).

## 2026-11-11 — sumeet: 2-day demo plan
- sumeet: **New priority: a working demo in 2 days.** The 12-week plan is paused. Plan is in `PLANNER.md` §0.
- sumeet: Created branch `demo` from `p2/signed-alerts`, so it has all of Shruj's P2 work and all of Tanisha's P1 work.
- sumeet: **Demo story:** sign up with an email code → add a contact, who taps "Get alerts on Telegram" → start a journey → SOS or missed check-in → contact gets a **Telegram** alert → offline, the phone sends a normal SMS.
- sumeet: Decisions: email code is the only sign-up check; **Telegram is the only alert channel** for the demo; no app lock; no Firebase push. Phone-number code over Twilio WhatsApp is **future scope** (`P2-LATER-whatsapp-phone-otp`).
- sumeet: Jobs: sumeet makes the Telegram bot and runs the server on a laptop (`ALL-W1-demo-branch-server`); shruj proves a real Telegram alert arrives (`P2-W1-demo-telegram-live`); tanisha connects the app to the server (`P1-W1-demo-api-wiring`); jival does the demo script and slides (`ALL-W1-demo-script-slides`).

## 2026-11-11 — shruj: Signed alerts
- Shruj: Built `P2-W6-signed-alerts` on branch `p2/signed-alerts` (stacked on `p2/location-relay`). Contacts can now tell real SixthSense alerts from fakes.
- Shruj: **Push alerts are signed.** Each push carries the alert details plus an Ed25519 signature. The app checks it with SixthSense's public key (`GET /notifications/signing-keys`, no sign-in; Tanisha can also build the key into the app). A changed or forged alert fails the check.
- Shruj: **Telegram and email alerts get a verification code** like `3VYM-5UV5`. The SixthSense app shows the same code on that alert (`GET /escalations/active`). If someone fakes a Telegram or email alert, the code won't match. Codes are different for each contact.
- Shruj: New `.env` keys: `ALERT_SIGNING_KEY` (generate once, command in `.env.example`; refused outside dev if left at the default) and `ALERT_SIGNING_KEY_PREVIOUS` for rotating without breaking older alerts.
- Shruj: Not covered: the SMS the phone sends by itself when offline, since contacts may not have the app to check it.
- Shruj: `contracts/openapi.yaml` explains exactly what is signed and how to verify it.
- Shruj: Checks: ruff clean, 178 tests pass (6 new, incl. tampered and forged alerts rejected, key rotation). Live: a real alert email's code matched the code in the app. Also fixed one older test that picked up leftover journeys from manual runs in the dev database.
- Shruj: **After pulling:** copy the signed-alerts block from `.env.example` into your `.env`.
- **Needs Tanisha:** verify push alerts with the signing key; show `verification_code` on the contact's alert screen.
- **Next:** `P2-W7-responder-alerts` needs P3's matching first. Meanwhile: Firebase + Telegram keys, and a "remove device" endpoint (W1 leftover).

## 2026-11-11 — shruj: Encrypted location relay
- Shruj: Built `P2-W5-location-relay` on branch `p2/location-relay` (stacked on `p2/watchdog-alert-ladder`). This is what Tanisha's location encryption (`P1-W6`) was waiting on.
- Shruj: **One WebSocket, `/relay/ws`.** The phone signs in with its first message (the token never goes in the URL, so it never lands in logs) and the token is re-checked on every message; when it expires the socket closes with code 4401 and the app reconnects.
- Shruj: **The server can't read locations.** The traveller sends her encrypted envelopes exactly as Tanisha's code produces them. The server only looks at the plain routing fields and checks: it's her own open journey, the sender key is her phone's current key, and each recipient is an accepted contact on the journey's alert list. Then it forwards the envelope unchanged, with her signing key attached so the contact's phone can verify it.
- Shruj: **Nothing is stored or queued** (ADR-3). If a contact isn't connected, that update is simply dropped. Strangers and removed contacts get nothing.
- Shruj: Location keeps flowing during a silent alarm, even after her phone was shown "resolved": that's when contacts need it most.
- Shruj: Limits: 1–10 envelopes per message, 10 messages per 5 seconds.
- Shruj: Connections live in the one API process, which fits the single pilot server; several API processes would need Redis pub/sub later (noted as a decision).
- Shruj: `contracts/openapi.yaml` documents the WebSocket protocol step by step (`/relay/ws`).
- Shruj: Checks: ruff clean, 172 tests pass (23 new). Live run over a real WebSocket: the contact got the envelope in 22 ms, unchanged; no token in the server's access log.
- **Needs Tanisha:** open `/relay/ws`, send the auth frame, send one envelope per contact device key (from `GET /contacts/{id}/keys`) every few seconds during a journey, keep sending during a silent alarm, ping every ~30 s, and decrypt incoming frames with the attached sender key.
- **Next:** `P2-W6-signed-alerts`.

## 2026-11-11 — shruj: Watchdog + alert ladder
- Shruj: Built `P2-W4-watchdog-alert-ladder` on branch `p2/watchdog-alert-ladder` (stacked on `p2/journey-state-machine`). The backend now actually alerts contacts.
- Shruj: **New worker**, run next to the API: `cd backend && uv run arq app.worker.WorkerSettings` (added to the README run table). Every 5 s it runs the journey watchdog, opens/closes alerts, sends what's due and links Telegram chats; every night it deletes journeys after 7 days and alerts after 90 days.
- Shruj: **How alerts go out:** all contacts at once. Each gets FCM push → Telegram → email, one minute apart, skipping channels they haven't set up, then the ladder repeats every 5 min for about an hour. The first "I'm on it" stops it for everyone. Triggering twice sends nothing extra.
- Shruj: **What contacts can do:** see open alerts (`GET /escalations/active`), "I'm on it" (`/ack`, or the link in the message, no sign-in), "They're safe" (`/resolve`: back to normal or journey ends; others get an all-clear), "I can't reach them" (`/raise`: urgent alert to everyone). Once someone says "I'm on it", a missed check-in no longer upgrades itself to a full alarm.
- Shruj: **Message wording:** no location ever. A silent alarm (duress PIN / covert SOS) says "Do NOT call their phone" so nobody tips off a coercer. If she checks in during an alert, contacts get "All clear".
- Shruj: **Contact setup:** `PUT /notifications/push-token` (FCM), `POST /notifications/telegram/link` (one-time t.me link, works without a public server), `PUT /notifications/email` (opt-in, must be their own sign-in email). FCM tokens, Telegram chat ids and emails are encrypted with the new `DATA_KEY`.
- Shruj: The server can't call 112 (no paid telephony); the phone does that.
- Shruj: Migration `0005` (core DB): `alert_channels`, `escalations`, `escalation_recipients`, plus `devices.fcm_token_enc` and `journeys.alert_acknowledged_at`. New `.env.example` keys: `DATA_KEY`, `PUBLIC_BASE_URL`, `FCM_*`, `TELEGRAM_*`. Firebase key files are gitignored. `contracts/openapi.yaml` updated (29 paths, matches the backend).
- Shruj: Checks: ruff clean, 149 tests pass (34 new, incl. real FCM/Telegram request formats against a fake network). Live run with the real worker: SOS → alert email in Mailpit in under a second → "I'm on it" via the link → resolved.
- Shruj: **After pulling:** copy the new alerts block from `.env.example` into your `.env`, `cd backend && uv sync && uv run alembic upgrade head`, and start the worker.
- **To do (Shruj):** email alerts work today. For push and Telegram, create a free Firebase project (download the service-account JSON) and a Telegram bot with @BotFather, then fill `FCM_*` and `TELEGRAM_*` in `.env`.
- **Needs Tanisha:** send the FCM token after sign-in; a "Get alerts on Telegram" button; an alert screen for contacts with I'm on it / They're safe / I can't reach them; open `…/escalations/ack#…` links.
- **Next:** `P2-W5-location-relay`.

## 2026-11-11 — shruj: Journey state machine
- Shruj: Built `P2-W3-journey-state-machine` in `backend/app/journey/`, on branch `p2/journey-state-machine` (stacked on `p2/trusted-contacts`).
- Shruj: **States:** active → check-in due → private prompt → contacts alerted → full escalation → resolved. A silent phone (no heartbeat) alerts contacts; SOS jumps straight to full escalation. The rules are plain functions in `state.py` with their own tests.
- Shruj: **The phone runs the timers and checks the PIN** (ADR-2); the server mirrors the same timers as a watchdog and catches up whenever the phone calls in.
- Shruj: **Duress:** the phone only sends `ok` or `duress` (the PIN never leaves it), and both get exactly the same response. A duress PIN or covert SOS escalates silently: the phone keeps seeing "active", and "resolved" if someone makes her tap Arrived, while the alarm keeps going. A real PIN never cancels a full escalation (a coercer could force it); contacts resolve it in W4.
- Shruj: **Endpoints:** `GET/PUT /journeys/protocol` (her timers, auto-112, which contacts to alert), `POST /journeys`, `GET /journeys/current`, `POST /journeys/{id}/heartbeat | check-in | prompt | sos | arrive | end`.
- Shruj: **Privacy:** no location, destination or route is sent or stored (rule 2). Journeys are deleted 7 days after they end.
- Shruj: Ready for W4: `service.run_watchdog()` returns journeys that just escalated, and `service.purge_expired()` does the 7-day cleanup; W4 schedules them and sends the alerts. No alerts are sent yet.
- Shruj: Migration `0004` (core DB): `protocols`, `journeys`. `contracts/openapi.yaml` updated (19 paths, matches the backend).
- Shruj: Checks: ruff clean, 112 tests pass (46 new). Live run: duress check-in showed "active", arrive showed "resolved", database still `full_escalation`.
- Shruj: **After pulling:** `cd backend && uv run alembic upgrade head`.
- **Needs Tanisha:** send a heartbeat at least every 5 min during a journey (or the server alerts contacts after 10 min of silence); report check-ins as `ok`/`duress`, the missed-check-in prompt, SOS (covert or not), arrive/end; use the same timer values as `/journeys/protocol`.
- **Next:** `P2-W4-watchdog-alert-ladder`.

## 2026-11-11 — shruj: Trusted contacts
- Shruj: Built `P2-W2-trusted-contacts` in a new `backend/app/contacts/` module, on branch `p2/trusted-contacts` (stacked on `p2/email-otp-device-keys`, so it can be built before that PR merges).
- Shruj: **How you add a contact:** the app saves the contact's name and number on the phone only (for offline SMS), creates an invite link, and shares it with the phone's share button (WhatsApp, SMS...). The contact opens it, signs in with an email code and accepts. The server never sees the contact's name or phone number, and never emails them.
  - `POST /contacts/invites`: one-time link, valid 48 h. Max 5 contacts (accepted + pending), 10 invites per hour. The token sits after `#` in the link so it never reaches a web server.
  - `POST /contacts/invites/accept`: the contact accepts. Accepting twice is harmless; you can't add yourself.
  - `GET /contacts`: the owner's own list (pending/accepted). No contact details: the phone matches each `contact_link_id` to its saved name and number.
  - `DELETE /contacts/{id}`: **silent** removal (or cancel a pending invite). The row is deleted and nothing is sent to the contact.
  - `GET /contacts/{id}/keys`: an accepted contact's device keys, for Tanisha's location encryption. Owner only.
  - `PUT /auth/device/e2e-keys`: each phone uploads its X25519 + Ed25519 public keys (her encryption needs these; the sign-in key can't do it).
- Shruj: Rule 4: contacts get **no** list of the people they watch over. They'll only receive alerts (W4). This also keeps removal truly silent.
- Shruj: Migration `0003` (core DB only): `trusted_contacts` and `device_e2e_keys`. `contracts/openapi.yaml` now has all 10 endpoints.
- Shruj: Checks: ruff clean, 66 tests pass (32 new: sign-in required everywhere, invite/accept/list, expired/reused/unknown invites, self-invite, limit, rate limit, silent removal, contact sees nothing, key access rules, revoked devices, nothing in logs). Live run against real Redis + Mailpit OK.
- Shruj: **After pulling:** `cd backend && uv run alembic upgrade head`.
- **Needs Tanisha:** contacts screen → share invite link + open it in the app to accept; store name/number keyed by `contact_link_id`; upload E2E keys after sign-in. The invite URL base (`https://sixthsense.app/invite`) is a placeholder until we pick a deep-link domain (`INVITE_BASE_URL` in `.env`).
- **Next:** `P2-W3-journey-state-machine`.

## 2026-11-11 — shruj: Email OTP + device auth
- Shruj: Built `P2-W1-otp-device-auth` in `backend/app/identity/`. Sign in with a 6-digit email code once per phone; after that the phone signs in with its Android Keystore key.
  - `POST /auth/otp/request`: always answers `202 {"status":"sent"}` (no hint whether an account exists). Code lives 10 min, only its hash is in Redis. Limit: 3 per email and 10 per IP per 10 min.
  - `POST /auth/otp/verify`: 5 tries, then locked; single use. Creates a Tier 0 account (no ID, rule 1) and registers the phone's EC P-256 public key. Returns a 15-min access token + `device_id`.
  - `POST /auth/device/challenge` + `POST /auth/device/verify`: the phone signs a one-time server nonce; no email needed again on that phone.
- Shruj: Privacy: no plaintext email anywhere. Accounts are found by `HMAC(OTP_PEPPER, email)`; codes, tokens, nonces and IPs are stored only as keyed hashes in Redis. Logs say "otp issued"/"otp verified", nothing personal.
- Shruj: Migration `0002` (core DB only): `accounts`, `devices`, and an append-only `audit_events` table (a DB trigger blocks edits and deletes, rule 7).
- Shruj: Added **Mailpit** to `infra/docker-compose.yml`: every email sent locally lands in http://localhost:8025. Real sending is plain SMTP set in your own `.env` (e.g. Gmail app password). New `.env.example` keys: `OTP_PEPPER`, `TOKEN_SECRET`, `SMTP_*`. The API refuses to start outside dev with the default secrets.
- Shruj: `contracts/openapi.yaml` now has the 4 auth endpoints with exact formats, so Tanisha can wire up the onboarding screens.
- Shruj: Checks: ruff clean, 34 tests pass (happy path, wrong/expired/reused code, attempt lock, rate limits, same response for unknown email, device signature checks, nothing sensitive in logs or Redis, audit log can't be edited). Also ran it live against real Redis + Mailpit: email arrived, both sign-ins worked, replayed nonce rejected.
- Shruj: **After pulling:** `cp .env.example .env` again (or copy the new sign-in block into your `.env`), `docker compose -f infra/docker-compose.yml up -d --wait`, `cd backend && uv sync && uv run alembic upgrade head`.
- Shruj: This work is on its own branch `p2/email-otp-device-keys` (branched from `p2/otp-device-auth`); open a PR from there.
- **Next:** `P2-W2-trusted-contacts`. Not done yet: a "remove device" endpoint, and reading the real client IP behind a proxy (only needed once deployed).

## 2026-11-11 — sumeet: Merged setup/foundation into p1/android-device; sign-in by email
- Merged Sumeet's latest `setup/foundation` commit into Tanisha's branch. The only conflicts were in `PROGRESS.md` and `progress.json`, resolved by keeping the newest status from each side.
- **Sign-in now asks for an email, not a phone number** (₹0 plan: email codes are free, SMS codes cost money). `onboarding_flow.dart` has an email field with format validation, and the code screen says "we emailed". New test: `test/onboarding_email_test.dart`.
- Trusted contacts still have **phone numbers**, because offline SMS is sent by the user's own phone (free).
- Name tags normalised from `Tan:` to `tanisha:` so everyone uses the same format.
- Checks: `flutter analyze` clean, 11 tests pass.
- **Shruj owns P2** and starts `P2-W1-otp-device-auth` on the new branch `p2/otp-device-auth`, which has all of the above.

## 2026-11-11 — tanisha: P1 map, route preview, and anonymous report privacy
- tanisha: Added a MapLibre/OpenFreeMap map screen with an explicit **Insufficient data** state and no route recommendation until P4 routing/risk data is available. Location permission is requested only when the user asks to center the map.
- tanisha: Added a category-only report form and on-device planar-Laplace location noise (100 m expected radial offset) plus two-hour local time buckets. The preview payload contains only the noisy point, category, and time bucket; no report is uploaded while the P4 endpoint is unavailable.
- tanisha: `flutter analyze`, all 10 tests, `flutter build apk --debug`, `git diff --check`, `progress.json` parsing, and iOS plist validation pass. Manual map/location preview steps are in `mobile/README.md`.

## 2026-11-11 — tanisha: P1 Walk With Me screens
- tanisha: Added traveller and companion preview flows, public meeting-point selection, sample profile, four-digit handshake screen, local masked chat with phone-number rejection, companion duty toggle, pose prompt, and camera selfie capture. Android blocks screenshots throughout the Walk With Me flow.
- tanisha: Camera bytes stay in memory and the temporary image is deleted after reading. Ending the demo clears chat/selfie from memory and removes profile/route from the completion view.
- tanisha: `flutter analyze`, all 7 tests, and `flutter build apk --debug` pass. Manual flow steps are in `mobile/README.md`. Real matching, shared handshake verification, remote masked chat, and liveness detection remain P3 service work; the screens clearly identify the demo limitations.

## 2026-11-11 — tanisha: P1 end-to-end location encryption client
- tanisha: Added a versioned, per-recipient location envelope using X25519, HKDF-SHA256, AES-256-GCM, and Ed25519 signatures. Coordinates, accuracy, timestamp, and sequence remain encrypted; decryption verifies signature, session/recipient binding, authentication tag, and replay watermark.
- tanisha: Added round-trip, ciphertext-metadata, tampering, context-binding, and replay tests. `flutter analyze`, all 5 widget/crypto tests, and `flutter build apk --debug` pass.
- tanisha: Live GPS publishing and relay are not connected: authenticated device-key provisioning, trusted-contact public-key lookup, and the ciphertext WebSocket relay are P2 dependencies still open. W6 stays in progress until those integrations are available.

## 2026-11-11 — tanisha: P1 offline SMS and low-battery mode
- tanisha: Added an opt-in journey SMS contact, runtime SMS/location permissions, and Android Keystore encryption for that contact until the journey ends.
- tanisha: Offline SOS, covert SOS/duress, and missed check-ins submit SMS with a Maps link when a fresh last-known location is available. At 10% battery or lower, the app submits one low-battery SMS and routes later journey alerts through SMS.
- tanisha: Documented carrier and low-battery manual checks in `mobile/README.md`; physical SIM checks were not run. `flutter analyze`, `flutter test` (2 tests), `flutter build apk --debug`, and `git diff --check` pass.

## 2026-11-11 — tanisha: P1 Android SOS shortcuts
- tanisha: Added the foreground Volume Up → Volume Down → Volume Up pattern, a user-added Quick Settings SOS tile, and a home-screen SOS widget. Each routes to the same local SOS notification; no contact or emergency alert is sent.
- tanisha: Documented shortcut setup, test steps, foreground-only volume detection, and the placeholder onboarding behavior (no OTP is sent or verified; contacts can be skipped).
- tanisha: `flutter analyze`, `flutter test` (2 tests), and `flutter build apk --debug` pass. Manual tile/widget/volume checks are listed in `mobile/README.md`.

## 2026-11-11 — tanisha: Updated P1 status for Android-first plan
- tanisha: Synced the task branch with the latest Android-first plan and updated P1’s next tasks and blockers.

## 2026-11-11 — tanisha: P1 Android journey emulator check
- tanisha: Tanisha manually tested the journey timer flow on the emulator and reported it is working well so far.
- tanisha: Physical USB-device and vendor battery-saver checks remain deferred.

## 2026-11-11 — tanisha: P1 Android journey service and alarms
- tanisha: Added an Android foreground service with a private ongoing notification and exact, allow-while-idle check-in alarms; check-in resets the alarm and ending a journey cancels it.
- tanisha: Added notification and exact-alarm permission handling, an optional battery-optimization exemption action, and alarm rescheduling after device reboot. Android stores only the active flag and next deadline; destination and PINs are not persisted.
- tanisha: Made the countdown content scale down on compact screens and kept the prototype limitation clear: missed check-ins do not alert contacts, and SOS/duress do not send alerts yet.
- tanisha: Added manual emulator verification steps to `mobile/README.md`. `flutter analyze`, `flutter test`, and `flutter run -d emulator-5554` pass; Tanisha later reported the emulator timer flow is working well so far. Physical-device checks were deferred at Tanisha’s request.

## 2026-11-11 — tanisha: P1 Android emulator run
- tanisha: Started `Medium_Phone_API_37.0` directly after Flutter's emulator launcher failed to register it with ADB.
- tanisha: Built, installed, and launched the Flutter app on `emulator-5554`; confirmed the app process is running. The first Android build installed NDK 28.2.13676358 and Android SDK Platform 36.
- tanisha: The physical Android phone USB-debugging check remains open, so `P1-W0-android-device` is in progress.

## 2026-11-11 — tanisha: Updated P1 status for Android-first plan
- tanisha: Synced the task branch with the latest Android-first plan and updated P1’s next tasks and blockers.
- tanisha: `flutter doctor` confirms Flutter and Android SDK 36.0.0 are ready.

## 2026-11-11 — tanisha: Reconciled progress during upstream pull
- tanisha: Kept the latest upstream Android-first setup notes and reconciled the P1 work log during the rebase.
- tanisha: Tried to launch `Medium_Phone_API_37.0`; Flutter and ADB did not detect a running Android device, so app-on-emulator verification remains open.

## 2026-11-11 — tanisha: P1 SOS and duress PIN
- tanisha: Added an SOS action with a clear prototype limitation message, a hidden long-press gesture on the lamp icon for covert SOS, and separate check-in/duress PINs. Three wrong PINs trigger the silent coercion handler.
- tanisha: Both PINs use the same obscured entry screen. PINs remain in memory only; SOS/duress do not contact anyone yet. Android volume-button, Quick Settings, and widget triggers are tracked separately.
- tanisha: `flutter analyze` passes and both widget tests pass, covering timer due/reset, normal and duress PIN handling, SOS, and covert SOS.

## 2026-11-11 — tanisha: P1 journey screens and on-device timer
- tanisha: Added journey setup (destination and check-in interval), active countdown, check-in due state, and timer reset on check-in; the countdown is local to the phone.
- tanisha: The timer refreshes when the app returns to foreground. Android foreground service/exact alarms, escalation, and persistence across app termination remain open.
- tanisha: `flutter analyze` passes and both widget tests pass, including the countdown-to-due and check-in-reset flow.

## 2026-11-11 — tanisha: P1 Flutter toolchain check
- tanisha: Reran `flutter doctor` after the platform plan changed: Flutter 3.47.9 and Android SDK 36.0.0 pass; Xcode and the iOS simulator remain installed for the later iOS port.

## 2026-11-11 — tanisha: P1 sign-up and contacts UI
- tanisha: Added a phone-number entry screen, verification-code screen, and trusted contacts screen with add/remove flows and privacy guidance.
- tanisha: This is a local UI flow; email-code delivery and contact persistence await the shared API contract and P2 endpoints.
- tanisha: Next, connect the screens after `ALL-W1-api-contract`; Flutter toolchain setup is now complete.

---

## 2026-11-11 — sumeet: App runs on Android emulator
- First debug build done and installed on the emulator: the SixthSense home screen shows in the Lamplight colours. `P1-W0-flutter-shell` is **done**.
- The first build took ~30 min (downloads Gradle, the Android NDK and SDK Platform 36 once). Later builds take about a minute.
- Tip: if the emulator shows a black screen, it's asleep: click the emulator's power button.

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
