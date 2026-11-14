# Integration plan: one SixthSense pipeline

**Prepared by Tan · 2026-11-14**  
**Purpose:** give the team a concrete merge and integration order for the work now on the pulled branches. This is a handoff plan; it does not merge branches or change runtime code.

## 1. What has arrived

The latest `origin/p3/walk-with-me` branch is the broadest integration base. Its merge base with `origin/demo` is the current demo commit, so it carries the demo sign-in, contacts, journey, Telegram and server wiring. It also descends from `integration/safe-routes-sos`, which brought together nearby responders, sudden SOS/audio escort work, and the safe-route/Insight work. Shruj then added the profile, mock companion verification, matching, walk feedback and admin export commits.

| Source | Work present | Integration concern |
|---|---|---|
| `origin/demo` | OTP/device keys, contacts, journeys, escalation/Telegram demo, API wiring | Already an ancestor of `origin/p3/walk-with-me`; do not merge it a second time without checking ancestry. |
| `origin/integration/safe-routes-sos` (in the Walk branch ancestry) | P3 nearby responders, volume/voice SOS, audio evidence/escort and relay, safe routes and privacy-log fixes | Preserve the distinct E2E audio/location rules and the separate Insight database. |
| `origin/p3/walk-with-me` | Profile API/tab, companion availability and approvals, nearby walk requests, accept/decline, handshake, two-way E2E walk location, companion SOS recipient, feedback and CSV admin tools | Its companion verification is explicitly a mock that always passes. It does not contain the strict CompreFace identity verification or reusable face-template implementation. |
| `p1/responder-verification` (this branch) | `eligible()` gates, ID/selfie CompreFace verification, HMAC-only identity outcomes, role-scoped responder profiles, revocation cleanup and encrypted reusable face templates | Its verification files and `0008` migration were developed on a branch without the sudden-SOS `0007` or Walk With Me `0008`; reconcile before integration. |

Shruj reports that the Walk With Me branch passes backend, Insight and Flutter checks, APK build, a 32-check local API run, and emulator flows with a scripted partner. The two-real-phone run is still outstanding. The face-template branch has static checks recorded but has not had its migration or live CompreFace check applied. Treat each as evidence for that branch only; run the full checks again after integration.

## 2. Recommended integration target

Create a new shared integration branch from `origin/p3/walk-with-me`, then merge `origin/p1/responder-verification` into it with targeted conflict resolution. This retains the already-tested Walk With Me implementation and its demo/sudden-SOS/safe-route ancestry, while bringing in the stricter identity system.

Do not resolve conflicts by taking one whole side for `backend/app/verification/`, `backend/app/walks/`, `backend/app/main.py`, `backend/app/core/config.py`, `backend/app/relay/`, `mobile/lib/core/api/device_identity.dart`, `mobile/lib/features/walk/walk_flow.dart`, `mobile/lib/features/journey/journey_flow.dart`, `contracts/openapi.yaml`, or the progress files. These paths contain complementary features or opposing security decisions.

## 3. Decisions the integration owner must enforce

1. **One identity decision:** the CompreFace ID/selfie result and `IdentityRecord` are the source of truth. Remove the always-pass `/walks/companion/verify` path from the normal build. A development mock may remain only behind an explicit server-side demo flag and must not grant production eligibility.
2. **One role-approval decision:** identity verification and role approval are separate. A person can be a verified responder, companion, both, or neither. Reuse one role-eligibility rule (`eligible(db, account_id, role, now)`) for presence, candidate search, offers/acceptance, walk relay and responder relay. Do not let `CompanionProfile.status`, `ResponderProfile.status`, a client flag, or the old `verified_method="mock"` independently grant access.
3. **Companion preference remains separate:** `Profile.willing_companion` is a user's opt-in to being discoverable as a companion, not identity proof or approval. A traveller can use journeys, routes, check-ins and every SOS path without ID verification.
4. **Fresh selfie must gate the actual accept transition:** the current face-template branch's general `POST /walks/face-check` is not tied to a particular invitation; a modified client could call `/walks/{id}/accept` directly. Integrate the face check into the accept boundary. Preferred design: accept the fresh selfie as multipart on `POST /walks/{walk_id}/accept`, validate the pending invitation and eligible companion, compare the selfie to the account's encrypted template, and only then transition the walk to accepted. If acceptance must remain a separate request, issue and consume a short-lived, one-use proof bound to account + walk + current template version. Never rely on a Flutter-only check.
5. **Recurring-template consent:** keep separate, explicit consent for retaining the encrypted CompreFace embedding. A companion cannot accept a walk without an enrolled template and a passing fresh face match. Declining template retention must not block traveller protection or ordinary responder access. Revoke consent/delete template and role eligibility must take effect on subsequent accepts.
6. **A passing face match is not liveness or ID authenticity.** Keep that limitation visible in app copy and demo narration; do not call it liveness verification.

## 4. Merge and schema sequence

### Step A — Freeze and map the branches

- Create `integration/full-pipeline` from the latest `origin/p3/walk-with-me` and record its exact base SHA.
- Fetch and record the exact `origin/p1/responder-verification` SHA being integrated.
- Preserve both source branches. Do not force-push or reset a teammate's branch.
- Back up each local Core database and record its Alembic revision and schema before applying integration migrations. Do not use `alembic stamp` or drop a database to hide a revision mismatch.

### Step B — Reconcile Alembic history before running the app

The pulled Walk With Me branch has `0007_audio_escorts.py` followed by `0008_walk_with_me.py`. The responder-verification branch independently names its identity migration `0008_identity_verification.py` with `down_revision="0006"`, and its face-template migration is `0009_reusable_face_templates.py`. The two different files both claim revision `0008`; migration `0009` also assumes that `0008` is identity verification. Alembic cannot treat that as one consistent chain.

For the new integration branch, use one explicit chain, for example:

```text
0001 … 0006 (shared core)
0007_audio_escorts
0008_walk_with_me
0009_identity_verification (rebased from the current 0008 identity migration)
0010_reusable_face_templates (rebased from current 0009)
```

Update both `revision` and `down_revision`, then inspect the full migration graph and the generated SQL. Add a forward-only compatibility migration or a documented schema-aware local-database conversion for any DB that already applied the old identity `0008`; the existing Walk With Me `0008` DB must also upgrade cleanly. Verify both layouts from backups before the team shares a DB. Keep Insight migrations in Insight's independent migration tree/database.

### Step C — Merge backend data and eligibility models

- Keep all Walk With Me entities and operations: `profiles`, `walks`, requests, feedback, rough-area Redis state, handshake derivation, notifications, and lifecycle cleanup.
- Keep the identity-verification entities: `verification_sessions`, `identity_records`, encrypted `face_templates`, and the single eligibility check.
- Remove duplicate trust truth. Prefer role approval in the role-scoped `responder_profiles` model used by `eligible()`; migrate/translate the Walk With Me companion approval row and admin script to that canonical source. Keep `willing_companion` as the profile preference. If the team chooses to retain `companion_profiles`, make it non-authoritative and ensure every operation still checks `eligible()`.
- Merge all settings instead of replacing one `Settings` class: SMTP/Telegram, responder presence, walk TTL/radius, CompreFace, identity HMAC, `FACE_TEMPLATE_KEY`, and audio/safe-route settings must coexist. Keep secrets in local environment files, never in commits.
- Mount all modules together in `backend/app/main.py`: identity, contacts, journey, escalation, notification, matching, verification, walks, profiles, feedback, escorts, relay, comms, routing and trust/safety as applicable.

### Step D — Replace the mock verification/approval flow

- Make verification sessions role-aware (`responder` or `companion`) while retaining one account-level verified identity. Require normal verification consent, selected ID type, ID number/DOB input, ID photo, selfie and CompreFace match; keep raw ID/DOB/photo out of database rows and logs.
- For Walk With Me companions, require the separate recurring-template consent before the companion can be approved/available to accept walks. Save only the encrypted embedding, consent metadata and calculator version. Preserve status, re-enrollment, deletion and fail-closed model-version checks.
- Update the companion app flow from “demo verification always passes” to: profile says willing → real verification/template status → pending campus approval → approved → available. Keep the responder application flow independent.
- Update `scripts/companions.py` and `scripts/responders.py`: list identity + role-approval state; refuse approval when `eligible()` would fail apart from the approval decision; revoke via one audited service that removes Redis presence and makes open offers/walks/relay inaccessible.
- Preserve rate limits and audit events. A user with no ID remains able to travel, run a journey, check in, send normal/covert/voice/volume SOS and contact their trusted people.

### Step E — Wire the actual Walk With Me lifecycle through the face gate

The intended run-time path is:

1. **Sign in:** email OTP binds the device key; subsequent launches use silent device sign-in. Nothing about identity verification is required for ordinary travel.
2. **Profile:** ask the user for the minimal partner profile after sign-in. The user may skip it. `willing_companion` is opt-in; profile visibility is limited to an active walk request/session.
3. **Companion enrollment:** a user choosing companion mode completes real ID/selfie matching, separately consents to the reusable template, then waits for manual approval. The server reports verified, pending approval, approved, revoked and template-enabled states distinctly.
4. **Availability:** only an approved, eligible, willing companion may publish the coarse Redis presence; refresh on the documented cadence and clear on going off duty, revocation or expiry.
5. **Traveller request:** traveller starts an open journey, selects a destination/route on-device, searches for available eligible companions by coarse location, and asks one. Send only first name/rough area to the invited companion. Request expires after 10 minutes; only one open request per traveller and a busy companion is excluded.
6. **Companion acceptance:** companion receives the invitation, captures a fresh selfie, and submits it at the server's walk-scoped accept boundary. The server checks identity validity, adult status, companion approval, cooldown, template presence/model version and face-match threshold. Only a pass may accept. A mismatch leaves the request unaccepted; outages fail closed with a retryable error. Rate-limit repeated attempts and audit pass/fail without image, score, ID or DOB.
7. **Active walk:** return the same four-digit handshake code to both sides (derived, not stored), a public rough meeting point, and only the two participants' E2E keys. Relay walk location under the walk ID to the other participant only. Destination and exact coordinates are not sent to the companion. Journey timers/check-ins remain active.
8. **SOS during a walk:** a normal, covert, volume, voice or duress SOS continues the existing contact/responder ladder and additionally alerts the active companion. Companion acknowledgement may show “I'm on it” but cannot resolve or raise the contacts' alert or stop their ladder. Validate that audio ciphertext recipients are exactly the permitted contacts/responders/companion for that active state, and that the live walk-location relay remains pair-only.
9. **Close:** either side can end the walk; ending the journey ends the walk. Clear walk area/presence and stop location/audio/chat access immediately. Show the appropriate feedback sheet; only the journey owner submits feedback, once per journey/walk. Companion cannot submit traveller feedback.

### Step F — Merge the Flutter surfaces and API contract

- Use the real Walk With Me `walk_flow.dart` as the base; merge verification, profile and feedback controls into it rather than restoring the former sample-match/local-chat prototype.
- Preserve the current CompreFace verification screens, OCR autofill/review, optional template consent, template re-enrollment/delete, and image/temp-file cleanup. Add companion-specific copy/status and require the fresh selfie at the accept boundary.
- Merge `DemoApi` methods: do not drop OTP/device auth, contacts, journeys, responder calls, new profile and feedback calls, Walk With Me routes, escorts, safe routes, audio relay, or verification. Keep shared token renewal and multipart helpers consistent; do not log image bodies or coordinate query strings.
- Update onboarding/profile, Plan a journey, active journey, Walk With Me, I support/companion alert, feedback and Respond screens as one navigation path. Ensure one navigator/API instance is used so URLs/tokens/config are not silently different.
- Reconcile `pubspec.yaml` dependencies instead of choosing a lockfile from either side; run `flutter pub get` after the combined manifest is final. Keep Android platform changes from sudden SOS/audio and camera support.
- Merge `contracts/openapi.yaml` from the actual route implementations. It must describe auth, roles/consent, profile, verification/template, walk-scoped face check/accept, walk lifecycle, relay/audio, feedback, alerts and safe routes with correct error cases. Contract and API tests must agree.

## 5. Full-pipeline acceptance run

Run in order on the integrated branch and shared local stack:

1. Start the full Compose stack (Core DB, Insight DB, Redis, NATS, CompreFace), apply the Core migration chain and Insight migrations, set API keys/secrets, start Core API, Insight API and worker.
2. Sign up a traveller and companion on separate devices. Confirm OTP, device-key sign-in and silent relaunch; confirm the traveller can use SOS without verification.
3. Create/skip/edit profiles; verify skipped profiles are not discoverable and names/bios are only exposed to the active requested partner.
4. Verify a companion with a matching ID portrait/selfie, save the face template by separate consent, and approve the companion. Also verify mismatch, missing template, expired/revoked identity, wrong role, cooldown, duplicate and matcher outage fail safely. Confirm no raw ID/DOB/images in Core DB, audit rows or logs.
5. Verify companion availability/search/request expiry/accept/decline and a fresh face match on every accepted request. Try direct accept without a fresh proof and replayed proof; both must fail. Delete the template and confirm the next accept is blocked; re-enroll and retry.
6. Confirm handshake codes match; move each phone and verify only the pair sees E2E location. End from both sides and via journey end; confirm Redis and relay access clear.
7. During an active walk, run check-in, missed check-in, normal SOS, covert/volume/voice SOS, duress and audio escort. Confirm trusted-contact alerts continue independently; companion sees only their permitted alert/ack controls and cannot resolve/raise. Verify relay cannot route to a revoked or unrelated device.
8. Submit journey/walk feedback once; verify duplicates and unauthorized authors are refused. Export admin feedback and confirm no names, routes, ID data or coordinates appear.
9. Test safe-route queries and reports against Insight's separate DB; confirm no account token/user ID crosses zones and route coordinates are absent from logs. Verify day/evening/night ranking and no “safe” label.
10. Run the complete backend, Insight, Flutter, Kotlin and contract checks, build the debug APK, then perform a two-real-phone ZeroTier run. Separately check screen-off volume SOS, voice trigger, camera framing, real CompreFace, Telegram, and journey timers on the target Android models.

## 6. Completion criteria and remaining non-code decisions

Integration is complete only when the single branch has one valid migration head, one canonical eligibility/approval path, no mock verification bypass in the normal app, the face check is inseparable from acceptance, all routes are mounted and represented in OpenAPI, and the end-to-end acceptance run above passes.

Before a campus pilot, the team still needs to decide/record: consent and retention wording for biometric templates and audio; who can approve/revoke companions; what happens to an active walk on revocation; whether leaving the companion screen should automatically clear availability; full-alert closure when there are no trusted contacts; and real-phone checks for audio, screen-off SOS and battery management. These decisions must be documented with owners in `progress.json` before marking pilot readiness.

## 7. Suggested responsibility split

- **Sumeet (integration/demo owner):** create the integration branch, choose/record migration compatibility policy, coordinate approval/retention decisions, run full local stack and two-phone demo.
- **Shruj (Core/Insight):** merge Core routers/models/migrations/relay/notifications/feedback, replace the mock companion path, centralize eligibility/revocation, and run backend + Insight suites.
- **Tan (mobile/verification):** merge CompreFace/template/consent UI into the real walk acceptance UI, reconcile `DemoApi` and navigation, validate Flutter/Android behavior.
- **Jival (demo):** update the walkthrough/slides to match real verification and visible limitations; rehearse only after the integrated acceptance run passes.

## 8. Useful source files

- Current strict verification: `backend/app/verification/`, `backend/app/matching/`, `backend/app/relay/`, `mobile/lib/features/verification/`, `backend/migrations/versions/0008_identity_verification.py`, `backend/migrations/versions/0009_reusable_face_templates.py`.
- Walk With Me integration branch: `backend/app/walks/`, `backend/app/profiles/`, `backend/app/feedback/`, `backend/scripts/companions.py`, `mobile/lib/features/walk/walk_flow.dart`, `mobile/lib/features/profile/`, `mobile/lib/features/feedback/`, `backend/migrations/versions/0008_walk_with_me.py`.
- Sudden SOS/audio/safe routes and nearby responders are documented in the `origin/p3/walk-with-me` ancestry and its `PROGRESS.md`; inspect `backend/app/escort/`, `backend/app/relay/`, `mobile/lib/features/sos/`, `mobile/lib/core/sos/`, `mobile/lib/core/routes/` and `insight/app/routing/` during merge review.
