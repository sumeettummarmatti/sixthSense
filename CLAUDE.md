# CLAUDE.md — SixthSense project context

> Claude Code loads this file automatically. Keep it short and current; details live in the linked files.

## What this is
SixthSense (called **SafeThread** in `Docs/`) is a safety app for women and children: **Avoid** risky routes, **Reduce** risk during a journey (check-ins, Walk With Me companions), **Interrupt** harm (parallel escalation, duress PIN, offline SMS), and **Fix** causes (anonymous place reports → campus dashboard). Campus pilot in ~12 weeks, 4-person team.

## Read first, every session
1. `progress.json` — **source of truth**: current phase, task statuses, blockers, next steps.
2. `PLANNER.md` — features, architecture, tech stack, lanes P1–P4, 12-week task IDs.
3. `Docs/` — full design (HLD, team split, verification & anonymity). Read the relevant section before building a feature.

## After any work (required)
- Update the task in `progress.json`: `status` (`todo | in_progress | blocked | done`), `notes`, plus `updated_at`, `next_steps`, and any new `decisions` / `blockers`.
- Add a short dated entry at the top of `PROGRESS.md` (what changed, decisions, what's next).
- New tasks get an ID `P<lane>-W<week>-<slug>` and go in both `PLANNER.md` and `progress.json`.

## Non-negotiable rules (reject any change that breaks one)
1. Protection never needs ID. Only companions/responders are verified.
2. Never store what we don't need: no live location, no ID documents/Aadhaar numbers, no route after a walk.
3. The phone must work alone: escalation timers run on the device; SMS fallback when offline.
4. Nobody sees anybody outside an active, consented session (contacts, companions, admins).
5. Never say "safe". Labels: *Strong evidence of concern* / *Some reports of concern* / *Insufficient data*. No green on maps.
6. Reports are about places, never people. Insight zone has **no user IDs** and its **own DB**; never import Core code or credentials into `insight/`.
7. Every sensitive action is logged append-only. Never log personal data (logs pass through the PII scrub filter, which is a safety net, not permission).

## Repo map
| Path | Stack | Lane |
|---|---|---|
| `mobile/` | Flutter 3.47 (Android + iOS). Theme in `lib/core/theme/app_theme.dart` | P1 |
| `backend/` | Python 3.12, FastAPI, SQLAlchemy 2, Alembic, uv. One package per module in `app/` | P2 / P3 |
| `insight/` | Same stack, separate service + DB (port 8001 / DB 5433) | P4 |
| `dashboard/` | Next.js 15 + MapLibre, pnpm 10.18 via corepack | P4 |
| `routing-engine/` | Valhalla (not started by default) | P4 |
| `contracts/openapi.yaml` | Shared API contract; change by PR | All |
| `infra/docker-compose.yml` | core-db :5432, insight-db :5433, redis :6379, nats :4222 | P2 |

## Commands
```bash
docker compose -f infra/docker-compose.yml up -d --wait
cd backend   && uv sync && uv run ruff check . && uv run pytest      # Core API :8000
cd insight   && uv sync && uv run ruff check . && uv run pytest      # Insight API :8001
cd dashboard && corepack pnpm install && corepack pnpm lint && corepack pnpm build
cd mobile    && flutter pub get && flutter analyze && flutter test
```
Run the relevant checks before claiming work is done. CI (`.github/workflows/ci.yml`) runs all of them plus Semgrep and Trivy.

## Conventions
- Branch per task: `p2/otp-device-auth`, `p4/clustering-threshold`. Never commit to `main` directly; open a PR.
- Commit messages start with the task ID when there is one (`P2-W1: ...`).
- Design colours: "Lamplight Lavender" (logo-sampled). Red only for SOS / strong evidence. Preview: https://claude.ai/artifact/5KNxV34PQeqNBWBQMXM6Xz
- Fonts must be bundled with the app, never fetched at runtime (privacy).
- pnpm 12 via corepack is broken on some machines; the dashboard pins `pnpm@10.18.0`.
