# SixthSense

> **See the risk. Stop it early.** Early, private, verifiable action for women's and children's safety, without ever becoming a tool to track the people it protects.

- **Plan:** [`PLANNER.md`](PLANNER.md) · **Status:** [`progress.json`](progress.json) / [`PROGRESS.md`](PROGRESS.md) · **AI context:** [`CLAUDE.md`](CLAUDE.md)
- **Colours:** [Lamplight Lavender preview](https://claude.ai/artifact/5KNxV34PQeqNBWBQMXM6Xz) (private: ask Sumeet for access)
- **Design docs:** [`Docs/`](Docs/) (the product is called *SafeThread* there)

## Repo layout

| Path | What | Lane |
|---|---|---|
| `mobile/` | Flutter app (traveller, companion, contact) | P1 |
| `backend/` | FastAPI modular monolith: Core zone (identity, journey, escalation, walks, ...) | P2 / P3 |
| `insight/` | FastAPI service: Insight zone (anonymous reports, clustering, risk), with its **own DB** | P4 |
| `dashboard/` | Next.js + MapLibre institution dashboard | P4 |
| `routing-engine/` | Valhalla config + safety costing | P4 |
| `contracts/` | `openapi.yaml`, the shared API contract | All |
| `infra/` | Docker Compose local stack (later: Terraform) | P2 |

## Quick start (local)

Prereqs: Docker, [uv](https://docs.astral.sh/uv/), Node 22 (pnpm via `corepack`), Flutter.

```bash
cp .env.example .env
docker compose -f infra/docker-compose.yml up -d --wait   # core-db, insight-db, redis, nats

# Core API → http://localhost:8000/docs
cd backend && uv sync && uv run alembic upgrade head && uv run uvicorn app.main:app --reload --port 8000

# Insight API → http://localhost:8001/docs
cd insight && uv sync && uv run alembic upgrade head && uv run uvicorn app.main:app --reload --port 8001

# Dashboard → http://localhost:3000
cd dashboard && corepack pnpm install && corepack pnpm dev
```

Tests: `uv run pytest` (backend, insight) · `corepack pnpm lint && corepack pnpm build` (dashboard) · `flutter test` (mobile).

## Team guide: how to pick up work

| Lane | Owns | Start in |
|---|---|---|
| **P1 Mobile** | Everything the user touches; on-phone timers, SOS, offline SMS | `mobile/` |
| **P2 Safety Core** | Login, contacts, journeys, alerts, relay, infra | `backend/app/{identity,journey,escalation,notification,relay}`, `infra/` |
| **P3 Trust** | Verification, Walk With Me, anonymity, T&S | `backend/app/{matching,walks,comms,trust_safety}` |
| **P4 Insight** | Reports, clustering, risk labels, routing, dashboard | `insight/`, `dashboard/`, `routing-engine/` |

1. **Pull `main`** and open [`progress.json`](progress.json). Find your lane's next `todo` task (or `next_steps`).
2. **Read** that task's row in [`PLANNER.md`](PLANNER.md) §6 and the matching section in [`Docs/`](Docs/).
3. **Branch:** `git checkout -b p<lane>/<slug>` (e.g. `p2/otp-device-auth`).
4. **Build + test** (commands above). Keep the [7 rules](#rules-we-never-break) intact.
5. **Update progress:** set your task's `status` and `notes` in `progress.json`, add a dated line at the top of `PROGRESS.md`.
6. **Open a PR** to `main`; CI must be green. API changes go through `contracts/openapi.yaml` and need a review from the lanes they affect.

### Working with Claude Code
[`CLAUDE.md`](CLAUDE.md) is loaded automatically in every Claude Code session. It holds the project summary, rules, repo map and the progress-update routine, so you don't need to re-explain the project. Prompts work best when they name the **task ID** and point at the **source section**:

```text
Work on P2-W1-otp-device-auth. Read progress.json, PLANNER.md §6 and
Docs/SafeThread_HLD_and_TechStack.md §4 (Auth & Identity) and §10 first.
Branch p2/otp-device-auth, add tests, then update progress.json and PROGRESS.md.
```

```text
What's blocked right now and what should P4 pick up next? (Answer from progress.json.)
```

```text
Review my branch against the 7 rules in CLAUDE.md before I open the PR.
```

## Rules we never break
1. Protection never needs ID. 2. Never store what we don't need. 3. The phone must work alone.
4. Nobody sees anybody outside an active session. 5. Never say "safe". 6. Reports are about places, never people.
7. Every sensitive action is logged in an append-only audit log.
