# Quickstart

Get Crucible running on your machine in under five minutes.

## Prerequisites

- **Docker** and **Docker Compose** (the easy path — one command, nothing to install locally)
- *Or* for native dev: Elixir 1.17+, OTP 27+, PostgreSQL 16+, Node 22+

You'll also need:
- An **Anthropic API key** (model calls)
- A **GitHub personal access token** with `repo` scope (so Crucible can push branches + open PRs against your workspaces)

## 1. Clone and configure

```bash
git clone https://github.com/brinkgenesis/crucible
cd crucible
cp .env.example .env
```

Open `.env` and fill in at minimum:

| Var | Required? | What it does |
|---|---|---|
| `ANTHROPIC_API_KEY` | **yes** | Model calls |
| `GITHUB_TOKEN` | **yes** | Branch push + PR creation |
| `SECRET_KEY_BASE` | **yes** | Phoenix session signing. Generate with `mix phx.gen.secret` (64-char). In Docker, any random 64+ char string is fine for dev. |
| `DATABASE_URL` | Docker fills this automatically | Postgres connection |
| `SANDBOX_MODE` | no (default `local`) | Set to `docker` for real container isolation |

The rest of `.env.example` is optional — set them when you want the corresponding feature (budget limits, alerting, OTel export, clustering, etc.).

## 2. Boot the stack

```bash
docker compose up
```

On first run this will:

1. Start Postgres on host port `55432` (avoids collision with a local Postgres on 5432)
2. Build the Crucible image (first build ~3–5 min; subsequent starts are instant)
3. Run migrations automatically via `/app/entrypoint.sh`
4. Start Phoenix on `http://localhost:4801`

You should see `Running CrucibleWeb.Endpoint with Bandit 1.10.3 at :::4801 (http)` in the logs. That's the "stack is up" signal.

## 3. Verify

```bash
curl http://localhost:4801/api/health/live
# => {"status":"ok","timestamp":"..."}

open http://localhost:4801
```

The kanban UI loads. Four main pages across the top:
- **Board** — cards and columns (this is where work happens)
- **Runs** — live trace view of in-flight runs
- **Cost** — aggregated spend by day / model / workflow
- **Control** — spawn interactive Claude Code sessions side-by-side

## 4. Create your first card

The easiest way to try it end-to-end: drop a card onto an existing repo you own.

1. Open the **Board** page.
2. Click **+ New card**.
3. Pick a workspace. If you haven't added one yet, go to **Settings → Workspaces** and add an entry pointing at a local git repo you've cloned.
4. Give the card a title (e.g. "Fix the broken test in `foo_test.exs`").
5. Paste a task description.
6. Pick a workflow (`simple-sprint` is the lightest — one coder, one PR).
7. Click **Create**.

Crucible will:
1. Generate a plan using the model router
2. Create an isolated git branch in the workspace
3. Run the coder phase (watch it live in **Runs**)
4. Open a PR against the workspace's default branch
5. Let the PR shepherd monitor CI and respond to review comments

## 5. Watch it work

- **Runs page** shows each phase's trace events as they land (tool calls, token usage, tool results).
- **Cost page** updates in near-real-time as the run accrues spend.
- **Control page** is for interactive sessions — not needed for the automated flow, but useful when you want to jump in and drive an agent directly.

## 6. Teardown

```bash
docker compose down         # stop containers, keep volumes
docker compose down -v      # stop AND wipe postgres + state volumes
```

## Native dev (without Docker)

If you want to hack on the code:

```bash
mix deps.get
mix ecto.setup              # creates DB + runs migrations
mix assets.setup
iex -S mix phx.server       # start with an IEx shell attached
```

You'll need a Postgres running locally. See [AGENTS.md](../AGENTS.md) for deeper dev workflow notes (precommit checks, test layout, how modules are organized).

## Common first-run snags

- **Port `:5432` already allocated** — you have a local Postgres. Either stop it, or set `POSTGRES_HOST_PORT` in `.env` (default is `55432`, already collision-safe).
- **`ANTHROPIC_API_KEY` missing** — model calls will fail with 401. The health endpoint still works; runs won't.
- **`GITHUB_TOKEN` missing or scope-less** — runs execute locally but the PR phase fails. Token needs `repo` scope.
- **Sandbox warning at startup** — `sandbox_enabled=true but SANDBOX_MODE=local` is expected on the default quickstart path. Set `SANDBOX_MODE=docker` when you want real isolation. See the README [Troubleshooting → Sandbox not isolating](../README.md#sandbox-not-isolating) section.

## Where to go next

- [Workflows guide](workflows.md) — how to pick a workflow, how phases compose, how to add your own
- [Self-improvement guide](self-improvement.md) — what the loop actually learns, how to read KPI snapshots, how to override a bad policy change
- [ARCHITECTURE.md](../ARCHITECTURE.md) — the 12-layer harness, supervision tree, adapter registry
- [CONTRIBUTING.md](../CONTRIBUTING.md) — dev setup, precommit, conventions
