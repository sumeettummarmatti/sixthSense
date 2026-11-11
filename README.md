# SixthSense

> **See the risk. Stop it early.** Early, private, verifiable action for women's and children's safety, without ever becoming a tool to track the people it protects.

| | |
|---|---|
| **Plan** | [`PLANNER.md`](PLANNER.md): features, architecture, 12-week schedule |
| **Status** | [`PROGRESS.md`](PROGRESS.md) (for people) · [`progress.json`](progress.json) (for Claude) |
| **AI context** | [`CLAUDE.md`](CLAUDE.md): loaded automatically by Claude Code |
| **Design docs** | [`Docs/`](Docs/) (the product is called *SafeThread* there) |
| **Platform** | **Android first** (iOS later; see `PLANNER.md` §3a) · **Budget ₹0** (free tools only, §3b) |
| **Team** | Sumeet · Tanisha (P1 Mobile) · Shruj · Jival |
| **Colours** | [Lamplight Lavender preview](https://claude.ai/artifact/5KNxV34PQeqNBWBQMXM6Xz) (private: ask Sumeet for access) |

---

## Contents
1. [Set up from scratch](#set-up-from-scratch) (about 45 minutes, mostly downloads)
2. [Run the project every day](#run-the-project-every-day)
3. [Check everything works](#check-everything-works)
4. [Troubleshooting](#troubleshooting)
5. [Repo layout](#repo-layout)
6. [Team guide: how to pick up work](#team-guide-how-to-pick-up-work)
7. [Rules we never break](#rules-we-never-break)

---

## Set up from scratch

> Written for **macOS** (Apple Silicon or Intel). On Windows or Linux, install the same tools from their websites; the project commands from step 4 onward are the same.
>
> Run every command in the **Terminal** app (press ⌘ + Space, type *Terminal*, press Enter). After each step, check the **✅ You should see** line before moving on.

### Step 1: Homebrew (the macOS package installer)

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

When it finishes, it prints two lines starting with `echo` under **Next steps**. Copy and run them, then close and reopen Terminal.

✅ You should see: `brew --version` prints `Homebrew 4.x` or newer.

### Step 2: Install the tools

Everyone on the team:

```bash
brew install git uv node@22 gh
brew link --overwrite --force node@22     # puts Node 22 on your PATH (it includes corepack/pnpm)
brew install --cask docker-desktop
```

People who will run the mobile app (P1, plus anyone testing it):

```bash
brew install --cask flutter android-studio
```

Then:
1. Open **Docker** from Applications once and wait for the whale icon in the menu bar to stop animating.
2. Log in to GitHub: run `gh auth login`, choose **GitHub.com → HTTPS → Login with a web browser**, and follow the prompts.

✅ You should see:

```bash
git --version        # git version 2.x
uv --version         # uv 0.9.x
node --version       # v22.x
docker info --format '{{.ServerVersion}}'   # a version number such as 27.3.1 (not an error)
gh auth status       # Logged in to github.com
```

### Step 3: Android toolchain (skip if you won't run the app)

We build for **Android first**, so you need Android Studio (installed in step 2). You don't need Xcode yet.

1. Open **Android Studio** from Applications. Choose **Do not import settings**, then **Standard** setup, accept every license, and click **Finish**. Wait for the downloads.
2. On the welcome screen, click **More Actions → SDK Manager → SDK Tools** tab.
3. Tick **Android SDK Command-line Tools (latest)**, **Android SDK Build-Tools** and **Android SDK Platform-Tools**. Click **Apply**, then **OK**.
4. Make an emulator: **More Actions → Virtual Device Manager → Create Virtual Device** (a **Pixel** phone is fine), pick the newest system image, click **Finish**.
5. Back in Terminal:
   ```bash
   flutter config --android-sdk ~/Library/Android/sdk
   flutter doctor --android-licenses      # type y and press Enter at each prompt
   ```

**Real phone (optional, recommended):** on the phone, open **Settings → About phone** and tap **Build number** 7 times. Then **Settings → Developer options → USB debugging** on. Plug it in and tap **Allow**.

✅ You should see: `flutter doctor` shows `[✓]` for **Flutter** and **Android toolchain**. (`[!]` or `[✗]` next to Xcode, Chrome or Connected device is fine.)

### Step 4: Get the code

```bash
cd ~/Desktop
gh repo clone sumeettummarmatti/sixthSense
cd sixthSense
cp .env.example .env
```

✅ You should see: `ls` lists `backend`, `dashboard`, `mobile`, `insight`, `PLANNER.md` and more.

### Step 5: Install project dependencies

Run from the `sixthSense` folder. Each line can take a minute or two the first time.

```bash
(cd backend   && uv sync)                    # also downloads Python 3.12 automatically
(cd insight   && uv sync)
(cd dashboard && corepack pnpm install)      # if asked to download pnpm, type Y
(cd mobile    && flutter pub get)            # skip if you skipped step 3
```

✅ You should see: each command ends without a red `error` line.

### Step 6: Start the databases and create the tables

```bash
docker compose -f infra/docker-compose.yml up -d --wait
(cd backend && uv run alembic upgrade head)
(cd insight && uv run alembic upgrade head)
```

This starts four services in the background: the **core database** (user data, port 5434), the **insight database** (anonymous reports only, port 5433), **Redis** (6379) and **NATS** (4222).

✅ You should see: `docker compose -f infra/docker-compose.yml ps` lists 4 services, each `healthy`.

**Setup is done.** Next, run the project.

---

## Run the project every day

Open **one Terminal tab per app** (⌘ + T for a new tab). In each tab, `cd ~/Desktop/sixthSense` first.

| Tab | What | Command | Open in browser |
|---|---|---|---|
| 1 | Databases (once; they keep running) | `docker compose -f infra/docker-compose.yml up -d --wait` | — |
| 2 | Core API | `cd backend && uv run uvicorn app.main:app --reload --port 8000` | http://localhost:8000/docs |
| 3 | Insight API | `cd insight && uv run uvicorn app.main:app --reload --port 8001` | http://localhost:8001/docs |
| 4 | Dashboard | `cd dashboard && corepack pnpm dev` | http://localhost:3000 |
| 5 | Mobile app | `flutter emulators --launch <name>` (see `flutter emulators`), then `cd mobile && flutter run` | opens on the emulator or your USB phone |

**To stop:** press **Ctrl + C** in each tab. To stop the databases: `docker compose -f infra/docker-compose.yml down` (your data is kept).

**After pulling new code:** re-run [step 5](#step-5-install-project-dependencies) and the two `alembic upgrade head` lines from [step 6](#step-6-start-the-databases-and-create-the-tables).

---

## Check everything works

Run this from the `sixthSense` folder before opening a pull request (there is no CI yet, so this is our safety net).

```bash
(cd backend   && uv run ruff check . && uv run pytest -q)                # "All checks passed!"  then "11 passed"
(cd insight   && uv run ruff check . && uv run pytest -q)                # "All checks passed!"  then "14 passed"
(cd dashboard && corepack pnpm lint && corepack pnpm build)              # no errors, then "Compiled successfully"
(cd mobile    && flutter analyze && flutter test)                        # "No issues found!"    then "All tests passed!"
```

With the APIs running (tabs 2 and 3):

```bash
curl -s localhost:8000/healthz     # {"status":"ok","service":"core"}
curl -s localhost:8001/healthz     # {"status":"ok","service":"insight"}
```

The test counts grow as features are added; what matters is that nothing says `failed`.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `command not found: brew` (or `flutter`, `uv`, ...) | Close Terminal and open a new window. If still missing, re-run the two `echo` lines from step 1. |
| `Cannot connect to the Docker daemon` | Open Docker from Applications and wait until it says it is running. |
| `port is already allocated` / `address already in use` | Something else uses that port. Find what is using it with `lsof -i :<port>`. Our databases use 5434 and 5433 so they do not clash with a local Postgres on 5432. |
| `corepack pnpm` fails with `Cannot find module ... pnpm.cjs` | Always run pnpm from inside `dashboard/`; it is pinned to `10.18.0` there. Newer pnpm 12 is broken with corepack on some machines. |
| `flutter doctor`: *cmdline-tools component is missing* | Redo step 3, items 2–3 (SDK Manager → SDK Tools). |
| `flutter doctor`: *Android license status unknown* | Run `flutter doctor --android-licenses` and type `y` at each prompt. |
| `flutter doctor`: Xcode `[✗]` | Ignore it: we're Android first. |
| `flutter run`: *No supported devices* | Start the emulator first (`flutter emulators --launch <name>`) or plug in your phone with USB debugging on; check with `flutter devices`. |
| First Android build fails with `java.net.ConnectException: Operation timed out` (downloading Gradle) | Java can't reach the download server, though your browser can. Download https://services.gradle.org/distributions/gradle-9.3.1-all.zip in the browser, then put it in the folder named in the error, under `~/.gradle/wrapper/dists/gradle-9.3.1-all/<random-folder>/` (delete any `.part` / `.lck` files there). Run the build again. |
| First Android build is slow (5–15 min) | Normal: it downloads Android build libraries once. Later builds take under a minute. |
| Phone doesn't show in `flutter devices` | Unplug and replug, tap **Allow USB debugging** on the phone, try another cable (some only charge). |
| `sudo: a terminal is required` | You ran `sudo` inside Claude Code. Run it in the macOS Terminal app instead. |
| `alembic upgrade head` can't connect | The databases aren't running: run step 6's first line and wait for `healthy`. |

Still stuck? Paste the full error into Claude Code with: *"This setup step failed, help me fix it."*

---

## Repo layout

| Path | What | Lane |
|---|---|---|
| `mobile/` | Flutter app (traveller, companion, contact), Android first | P1 |
| `backend/` | FastAPI: Core zone (identity, journey, escalation, walks, ...) | P2 / P3 |
| `insight/` | FastAPI: Insight zone (anonymous reports, clustering, risk), with its **own database** | P4 |
| `dashboard/` | Next.js + MapLibre campus dashboard | P4 |
| `routing-engine/` | Valhalla safe-routing engine (not started by default; see its README) | P4 |
| `contracts/` | `openapi.yaml`: the shared API contract | All |
| `infra/` | Docker Compose for local databases | P2 |

---

## Team guide: how to pick up work

| Lane | Owns | Start in |
|---|---|---|
| **P1 Mobile** (Tanisha) | Everything the user touches; on-phone timers, SOS, offline SMS (Android) | `mobile/` |
| **P2 Safety Core** | Login, contacts, journeys, alerts, relay, infra | `backend/app/{identity,journey,escalation,notification,relay}`, `infra/` |
| **P3 Trust** | Verification, Walk With Me, anonymity, trust & safety | `backend/app/{matching,walks,comms,trust_safety}` |
| **P4 Insight** | Reports, clustering, risk labels, routing, dashboard | `insight/`, `dashboard/`, `routing-engine/` |

1. **Get the latest code:** `git checkout main && git pull`
2. **Pick a task:** open [`PROGRESS.md`](PROGRESS.md) (the table at the top) or [`progress.json`](progress.json) and find your lane's next `todo`.
3. **Read** that task in [`PLANNER.md`](PLANNER.md) §6 and the matching section in [`Docs/`](Docs/).
4. **Make a branch:** `git checkout -b p<lane>/<short-name>`, for example `git checkout -b p2/otp-device-auth`
5. **Build it and test it**, keeping the [7 rules](#rules-we-never-break) intact. Run [Check everything works](#check-everything-works).
6. **Update progress, tagged with your name** (`sumeet:`, `tanisha:`, `shruj:` or `jival:`):
   - `progress.json`: set your task's `status`, start its `notes` with your name (`"tanisha: OTP screen done"`), and set `updated_by`.
   - `PROGRESS.md`: add an entry at the top: `## 2026-11-12 — tanisha: Sign-up screens`.
7. **Push and open a pull request:**
   ```bash
   git add -A && git commit -m "P2-W1: short description"
   git push -u origin HEAD
   gh pr create --fill
   ```
   API changes go through `contracts/openapi.yaml` and need a review from the lanes they affect.

### Working with Claude Code

[`CLAUDE.md`](CLAUDE.md) is loaded automatically in every Claude Code session, so you don't need to re-explain the project. Prompts work best when they name the **task ID** and point at the **source section**:

Start by saying who you are, so Claude tags progress with your name:

```text
I'm Tanisha (P1). Work on P1-W1-signup-contacts-ui.
```

```text
I'm Shruj. Work on P2-W1-otp-device-auth. Read progress.json, PLANNER.md §6 and
Docs/SafeThread_HLD_and_TechStack.md §4 (Auth & Identity) and §10 first.
Make branch p2/otp-device-auth, add tests, then update progress.json and PROGRESS.md.
```

```text
What's blocked right now and what should P4 pick up next? (Answer from progress.json.)
```

```text
Review my branch against the 7 rules in CLAUDE.md before I open the PR.
```

---

## Rules we never break

1. **Protection never needs ID.** Only companions are verified.
2. **Never store what we don't need.** No live location, no ID documents, no route after a walk.
3. **The phone must work alone.** No internet must not mean no safety.
4. **Nobody sees anybody outside an active session.** Not contacts, companions or admins.
5. **Never say "safe".** Only "Strong evidence of concern", "Some reports of concern" or "Insufficient data".
6. **Reports are about places, never people.**
7. **Every sensitive action is logged** in a log nobody can edit.
