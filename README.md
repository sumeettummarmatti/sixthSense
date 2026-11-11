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

## Check your setup

Run these before the quick start. Each line shows the command and what you should see (versions listed are what the project was set up with; newer is usually fine).

### 1. Core tools (everyone)

| Tool | Command | Expected | Install if missing (macOS) |
|---|---|---|---|
| Git | `git --version` | `git version 2.x` | `xcode-select --install` |
| Docker | `docker --version` | `Docker version 27.x` | [Docker Desktop](https://www.docker.com/products/docker-desktop/) |
| Docker running | `docker info --format '{{.ServerVersion}}'` | a version number, not an error | Open Docker Desktop |
| uv (Python) | `uv --version` | `uv 0.9.x` | `brew install uv` |
| Python 3.12 | `uv python find 3.12` | a path to Python 3.12 | `uv python install 3.12` |
| Node | `node --version` | `v22.x` | `brew install node@22` |
| pnpm | `corepack pnpm --version` (inside `dashboard/`) | `10.18.0` | `corepack enable` |
| GitHub CLI (optional) | `gh auth status` | `Logged in to github.com` | `brew install gh && gh auth login` |

### 2. Mobile toolchain (P1, and anyone running the app)

| Tool | Command | Expected | Install if missing |
|---|---|---|---|
| Flutter | `flutter --version` | `Flutter 3.47.x • channel stable` | `brew install --cask flutter` |
| Everything Flutter needs | `flutter doctor` | `[✓]` on Flutter, Android toolchain, Xcode | follow what it says |
| Android SDK | `ls ~/Library/Android/sdk` | `build-tools cmdline-tools emulator licenses platform-tools platforms` | Android Studio → More Actions → SDK Manager |
| Android cmdline-tools | `ls ~/Library/Android/sdk/cmdline-tools` | `latest` | SDK Manager → SDK Tools → **Android SDK Command-line Tools** |
| Android licenses | `flutter doctor --android-licenses` | `All SDK package licenses accepted` | type `y` at each prompt |
| Xcode (iOS) | `xcodebuild -version` | `Xcode 26.x` | App Store |
| Xcode first launch | `xcrun simctl list runtimes` | at least one `iOS ...` runtime | in Terminal: `sudo xcodebuild -runFirstLaunch && sudo xcodebuild -license accept` |
| CocoaPods | `pod --version` | `1.17.x` | `brew install cocoapods` |
| Devices | `flutter devices` | lists a simulator, emulator or phone | start one: `open -a Simulator` or Android Studio → Device Manager |

### 3. Project checks (after cloning)

```bash
# Local services: all four should say "healthy"
docker compose -f infra/docker-compose.yml up -d --wait
docker compose -f infra/docker-compose.yml ps --format '{{.Service}}: {{.Status}}'

# Backend: "All checks passed!" then "11 passed"
cd backend && uv sync && uv run ruff check . && uv run pytest -q && cd ..

# Insight: "All checks passed!" then "14 passed"
cd insight && uv sync && uv run ruff check . && uv run pytest -q && cd ..

# Dashboard: no lint errors, then "Compiled successfully"
cd dashboard && corepack pnpm install && corepack pnpm lint && corepack pnpm build && cd ..

# Mobile: "No issues found!" then "All tests passed!"
cd mobile && flutter pub get && flutter analyze && flutter test && cd ..

# APIs respond (with the servers from the quick start running)
curl -s localhost:8000/healthz   # {"status":"ok","service":"core"}
curl -s localhost:8001/healthz   # {"status":"ok","service":"insight"}
```

If a check fails, paste the output into Claude Code with: *"This setup check failed, help me fix it"*.

## Quick start (local)

Prereqs: everything in [Check your setup](#check-your-setup) passes.

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
