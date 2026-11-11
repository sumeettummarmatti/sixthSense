# SixthSense — Progress Log

> Human-readable session log (newest at top). Machine state lives in `progress.json`.

## 2026-11-11 — Colour system
- "Lamplight Lavender" palette sampled from the logo; preview: https://claude.ai/artifact/5KNxV34PQeqNBWBQMXM6Xz
- Applied to Flutter (`mobile/lib/core/theme/app_theme.dart`, light + night ColorScheme) and dashboard (`globals.css` tokens, colour-coded evidence legend).
- Rules: no green, red only for SOS / strong evidence, same colours on real and duress PIN screens.
- Still open: Android cmdline-tools, Xcode first launch, OK to start Docker.

## 2026-11-11 — M0 setup (branch `setup/foundation`)
- **Done:** repo root files, `infra/docker-compose.yml` (2× PostGIS on separate networks, Redis, NATS), `backend/` (10 module routers, PII-scrubbing logs, Alembic; 11 tests), `insight/` (own DB only, no-"safe" labels, k/m threshold, isolation tests; 14 tests), `dashboard/` (Next.js + MapLibre; build passes), `routing-engine/` Valhalla stub, `contracts/openapi.yaml` skeleton, CI + Dependabot.
- **Fixed along the way:** phone-number regex missed a leading `0`; pnpm 12 via corepack is broken here, so pnpm is pinned to 10.18.0.
- **Waiting on:** Flutter + Android Studio install; OK to start Docker containers.
- **Next:** Flutter shell in `mobile/`, bring up DBs and run migrations, push + PR, then the week-1 API contract.

## 2026-11-11 — Planning
- Synced local `main` with GitHub (`915c986`).
- Read all three design docs + logo. Wrote `PLANNER.md` (features, architecture, stack, P1–P4 lanes, 12-week task IDs, open items).
- Created `progress.json` (source of truth) and this log.
- **Decisions:** code name `sixthsense`; 4-person lanes; local-first setup; JSON + MD tracking.
- **Blockers:** Flutter not installed; legal review + campus MoU pending.
- Evaluated **xtool** (cross-platform Xcode replacement for SwiftPM iOS apps): not adopting — it can't build Flutter apps, and Xcode 26.4.1 is already installed. Android SDK still needed for Flutter Android.
- **Next:** start M0 setup on branch `setup/foundation` — monorepo, Docker Compose (2× PostGIS, Redis, NATS), FastAPI backend + insight skeletons, Next.js dashboard, Flutter shell, CI.
