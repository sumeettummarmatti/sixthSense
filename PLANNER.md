# SixthSense — Build Planner

> **See the risk. Stop it early.**
> Code name: `sixthsense`. Design docs call it *SafeThread* — same product.
> Source docs: `Docs/SafeThread_HLD_and_TechStack.md`, `Docs/SafeThread_Team_Split.md`, `Docs/SafeThread_Verification_and_Anonymity.md`.
> Live status: `progress.json` (source of truth) · `PROGRESS.md` (session log). Task IDs below match `progress.json`.

---

## 1. Product in one screen

SixthSense turns what people already sense about risk into **early, private, verifiable action** — without ever becoming a tool to track the people it protects.

| Window | Goal | Features |
|---|---|---|
| **Avoid** (before) | Don't walk into risk | Safety-weighted routing, evidence-aware labels |
| **Reduce** (during) | Never alone, never unwatched | Journey check-ins, Walk With Me |
| **Interrupt** (wrong) | Cut it short | Parallel escalation, duress PIN, covert SOS, offline SMS |
| **Fix** (after) | Remove the cause | Anonymous reports → clusters → campus dashboard |

### Features & scope

| # | Feature | MVP (campus) |
|---|---|---|
| F1 | Onboarding & trust tiers (OTP for all; ID+liveness only for companions) | ✅ |
| F2 | Journey protocol (check-ins → private prompt → contact → full escalation; duress PIN; covert SOS) | ✅ |
| F3 | Parallel escalation (contacts + 112 + responders at once; push → SMS → voice until ACK) | ✅ |
| F4 | Trusted contacts (E2E live location only during journeys; silent removal) | ✅ |
| F5 | Walk With Me (verified companion, handshake code, random public drop point) | ✅ campus companions |
| F6 | Verified responder network (~500 m coarse alerts) | Phase 2/3 |
| F7 | Anonymous reports (noised on device, k/m threshold) | ✅ |
| F8 | Evidence-aware labels (never "safe") | ✅ |
| F9 | Safety-weighted routing | ✅ basic |
| F10 | Institution dashboard (clusters, "addressed", report decline) | ✅ |
| F11 | Offline-first & battery-aware | ✅ |
| F12 | Child profiles | Phase 3 (legal review) |

### The 7 rules everyone owns (non-negotiable)
1. **Protection never needs ID.** Only companions/responders are verified.
2. **Never store what we don't need.** No live location, no ID documents, no route after a walk.
3. **The phone must work alone.** No internet ≠ no safety.
4. **Nobody sees anybody outside an active session** — not contacts, companions, or admins.
5. **Never say "safe."** Only: *Strong evidence of concern* / *Some reports of concern* / *Insufficient data*.
6. **Reports are about places, never people.**
7. **Every sensitive action is logged** in an append-only (WORM) audit log.

---

## 2. Architecture

```
Clients: Mobile app (traveller · companion · contact) | Institution dashboard | T&S console
   │
Edge: API gateway — TLS 1.3, rate limits, WAF, device attestation
   │
┌─ CORE ZONE (identifiable, live) ───────────────────────────┐   ┌─ INSIGHT ZONE (anonymous only) ─┐
│ Auth&Identity · Journey · Escalation · Notification ·      │   │ Report Ingestion → Clustering   │
│ Matching · Walk Session · E2E Relay · Masked Comms ·       │   │ + NLP → Risk layer              │
│ Routing · Trust & Safety                                   │   │                                 │
│ Postgres+PostGIS (core) · Redis · NATS · KMS               │   │ Postgres+PostGIS (insight, sep.)│
└────────────────────────────────────────────────────────────┘   └─────────────────────────────────┘
External: KYC (Aadhaar app / DigiLocker) · Liveness SDK · SMS/Voice CPaaS · FCM/APNs · 112
```

### Key decisions (ADRs)
| ID | Decision | Why |
|---|---|---|
| ADR-1 | Two trust zones, separate DBs + credentials | Analytics breach reveals no person |
| ADR-2 | Escalation timer runs **on the phone**; server is watchdog | Works offline / during outage (SMS + dialer fallback) |
| ADR-3 | Server relays location as **ciphertext only**, no persistence | Can't leak, sell, or be compelled |
| ADR-4 | Modular monolith first; extract Escalation + Notification first | Ship fast, split cleanly |
| ADR-5 | Buy identity, liveness, SMS, masking — **build policy** | Value = who sees what, when, for how long |
| ADR-6 | Per-session keys → crypto-shredding | Deletion that holds even in backups |

### Backend modules (core rules)
| Module | Key rule |
|---|---|
| identity | Store verification *outcome* only; dedupe = HMAC(pepper, name‖DOB‖gender); no Aadhaar no., no ID image |
| journey | Duress PIN shows the same screen as real PIN; 3 wrong PINs = coercion |
| escalation | Idempotent per journey; never waits on one channel; signed alerts |
| notification | Push → SMS → voice ladder, retries, delivery receipts |
| matching | Coarse cell only; per-hour caps; no re-match same pair 14 days; women-only/campus-only filters |
| walks | Per-walk pseudonyms; companion never sees destination; escrow shredded at 30 days |
| relay | Ciphertext only, no persistence |
| comms | Masked; channel expires 30 min after close |
| routing | No route logs tied to users |
| trust_safety | 2-officer unseal; immutable audit; instant suspension on complaint |
| insight (separate service) | No user ID; attestation token only; reject person-identifying text; publish only ≥5 reports from ≥3 devices |

---

## 3. Tech stack (final picks)

| Layer | Choice | Status |
|---|---|---|
| Mobile | **Flutter** + Kotlin/Swift platform channels | MVP |
| Mobile storage | Drift (SQLite) + SQLCipher; Keystore / Secure Enclave | MVP |
| Mobile E2E | libsignal (or OpenMLS) | MVP (W5–6) |
| Maps | MapLibre GL + OSM tiles | MVP |
| Integrity | Play Integrity / App Attest | MVP |
| Backend | **Python 3.12 + FastAPI**, SQLAlchemy 2 + Alembic, pydantic-settings | MVP (Go for hot paths later) |
| Realtime | FastAPI WebSockets | MVP |
| DBs | **PostgreSQL 16 + PostGIS** ×2 (core, insight) | MVP |
| Ephemeral | **Redis 7** (GEO, TTL, timers, rate limits) | MVP |
| Event bus | **NATS JetStream** | MVP (Kafka at scale) |
| Jobs | **Arq** on Redis (watchdog, retries, shredding) | MVP |
| Routing | **Valhalla** on OSM, custom costing | MVP (W7–10) |
| Insight ML | HDBSCAN / ST-DBSCAN, sentence-transformers (multilingual) | MVP (NLP later) |
| Dashboard / T&S | **Next.js (TS) + MapLibre** | MVP |
| Tooling | uv, ruff, pytest · pnpm, eslint · Docker Compose | MVP |
| CI | GitHub Actions + Semgrep + Trivy + Dependabot | MVP |
| Cloud | AWS Mumbai (ECS Fargate, RDS, KMS, S3 Object Lock), Terraform | **Later** (local-first now) |
| Observability | OpenTelemetry + Grafana/Prometheus + Sentry (PII scrub) | Later |
| Vendors | KYC aggregator, liveness SDK, DLT-registered CPaaS | Pick in W1–2 (P3/P2) |

---

## 4. Lanes (4-person team)

### P1 — Mobile App (Flutter)
*"The phone is the safety net. It must work with no internet."*
- **Never:** require ID to be protected · let a server problem stop an alert · upload exact report locations.
- **Needs:** P2 auth/journey/alert APIs · P3 walk/verification/handshake APIs · P4 routes/labels/report APIs.
- **Done when:** Wi-Fi + data off, miss a check-in → contact still gets an SMS with location.

### P2 — Safety Core Backend + Infra
*"When something goes wrong, the right people find out, fast."*
- **Never:** store live location · let contacts see location outside a journey/alert · notify a contact they were removed.
- **Needs:** P1 heartbeats/events · P3 "find nearby responders".
- **Done when:** SOS reaches contacts by push in seconds; auto-moves to SMS then call; duplicate trigger sends nothing extra.

### P3 — Trust: Verification + Walk With Me + Anonymity
*"Strangers are accountable during the walk and strangers again after it."*
- **Never:** store Aadhaar numbers/ID images · show a companion her home/destination/name/number · let one person open escrow.
- **Needs:** P1 selfie/handshake/chat UI · P2 login/contacts/notifications.
- **Done when:** red-team "companion" tries every way to re-find her after a walk and fails.

### P4 — Insight: Reports + Risk + Routing + Dashboard
*"Turn what people sense into fixes, without exposing anyone."*
- **Never:** link a report to a user · show a cluster below threshold · label anywhere "safe".
- **Needs:** P1 on-device blur + report/map screens · P2 infra.
- **Done when:** campus security sees a real cluster, marks it fixed, dashboard shows whether reports dropped.

### Interfaces between lanes
| From → To | What |
|---|---|
| P1 → P2 | Sign-up, contacts, journey events, heartbeats, SOS |
| P1 → P3 | Verification selfie, walk requests, handshake, chat |
| P1 → P4 | Blurred reports, route requests |
| P2 ↔ P3 | "Full alert: find responders" ↔ responder list |
| P4 → P1 | Routes + risk labels |
| P4 → Dashboard | Published clusters only |

---

## 5. Week-1 API contract

All four agree and write `contracts/openapi.yaml` before parallel work. Groups (HLD §9):
Auth · Verification · Contacts · Journey · Escalation · Walk · Responder · Reports · Routing · Dashboard · Realtime (WebSocket: ciphertext relay, alerts, walk updates).

---

## 6. 12-week milestones & task IDs

| Wk | Milestone (done when) |
|---|---|
| 0 | **M0 Setup** — monorepo, local stack, skeletons, CI green |
| 1–2 | **M1 Foundation** — user can sign up and add contacts |
| 3–4 | **M2 Journey + escalation** — missed check-in reliably reaches a contact, even offline |
| 5–6 | **M3 Verification + E2E** — verified companions exist; live location E2E |
| 7–8 | **M4 Walk With Me** — full walk end-to-end, nothing left behind |
| 9–10 | **M5 Reports + routing + dashboard** — campus security sees a real cluster |
| 11 | **M6 Red-team week** — every break found is fixed |
| 12 | **M7 Pilot** — live on one campus + external pentest |

### Task IDs by lane
| Wk | P1 Mobile | P2 Safety Core | P3 Trust | P4 Insight |
|---|---|---|---|---|
| 0 | `P1-W0-flutter-shell` | `P2-W0-monorepo` `P2-W0-local-stack` `P2-W0-backend-skeleton` `P2-W0-ci` | — | `P4-W0-insight-skeleton` `P4-W0-dashboard-shell` |
| 1 | `ALL-W1-api-contract` | ← | ← | ← |
| 1–2 | `P1-W1-signup-contacts-ui` | `P2-W1-otp-device-auth` `P2-W2-trusted-contacts` | `P3-W1-vendor-selection` | `P4-W1-report-model-separate-db` |
| 3–4 | `P1-W3-journey-ui-timers` `P1-W4-sos-duress-pin` | `P2-W3-journey-state-machine` `P2-W4-watchdog-alert-ladder` | `P3-W3-tier1-verification` `P3-W4-tier2-campus` | `P4-W3-report-intake-filters` |
| 5–6 | `P1-W5-sms-fallback-lowbattery` `P1-W6-e2e-location` | `P2-W5-location-relay` `P2-W6-signed-alerts` | `P3-W5-matching-rules` | `P4-W5-clustering-threshold` `P4-W6-risk-labels` |
| 7–8 | `P1-W7-walk-screens-handshake-chat` | `P2-W7-responder-alerts` | `P3-W7-walk-lifecycle` `P3-W8-close-wipe-escrow` | `P4-W7-valhalla-safety-costing` |
| 9–10 | `P1-W9-map-routes-report-blur` | `P2-W9-load-test-monitoring` | `P3-W9-complaints-ts-console` | `P4-W9-campus-dashboard-before-after` |
| 11 | `ALL-W11-red-team` | ← | ← | ← |
| 12 | `ALL-W12-pilot-pentest` | ← | ← | ← |

---

## 7. Open items / blockers (before or during build)
1. **Legal:** DPDP rules for children's monitoring; UIDAI offline-verification entity registration; responder liability; log retention vs crypto-shredding.
2. **Campus MoU** (aggregates-only data sharing) + campus security liaison.
3. **Vendors:** KYC aggregator + liveness SDK + DLT-registered CPaaS — sandbox access first.
4. **Escrow unseal policy:** approvers, timelines, user notification, transparency reporting.
5. **Languages:** Kannada + Hindi first.
6. **Local tooling:** Flutter not yet installed; pnpm via corepack.

---

## 8. Working agreement (progress tracking)
- **Start of every session:** read `progress.json` (current phase, in-progress tasks, blockers, next steps).
- **After any work:** update task `status` (`todo | in_progress | blocked | done`) + `notes`, bump `updated_at`, refresh `next_steps`, add any `decisions`/`blockers`, and append a short dated entry to `PROGRESS.md`.
- New tasks get an ID in the form `P<lane>-W<week>-<slug>` and are added to both this planner and `progress.json`.
- Branch per task/milestone (e.g. `setup/foundation`, `p2/otp-device-auth`); never commit directly to `main`.
