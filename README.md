# SixthSense

> **See the risk. Stop it early.** Early, private, verifiable action for women's and children's safety, without ever becoming a tool to track the people it protects.

- **Plan:** [`PLANNER.md`](PLANNER.md) · **Status:** [`progress.json`](progress.json) / [`PROGRESS.md`](PROGRESS.md)
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

## Rules we never break
1. Protection never needs ID. 2. Never store what we don't need. 3. The phone must work alone.
4. Nobody sees anybody outside an active session. 5. Never say "safe". 6. Reports are about places, never people.
7. Every sensitive action is logged in an append-only audit log.
