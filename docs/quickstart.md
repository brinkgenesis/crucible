# Quickstart

Get Crucible running on your machine in under five minutes.

## Why native, not Docker

Crucible drives real binaries on your host: it spawns `claude` CLI sessions, uses `tmux` panes for the Control panel, and runs `git` against repos on your disk. Running Crucible itself inside a Docker container hides all of that, so agent runs fail and Control does nothing. **Run Crucible natively.** Docker is optional and only used for the Postgres service if you don't already have one.

## Prerequisites

macOS (Homebrew):

```bash
brew install elixir postgresql@16 tmux
brew services start postgresql@16

# Claude CLI (needed for agent runs + Control panel)
npm install -g @anthropic-ai/claude-code
claude --version   # verify
```

Linux: install `elixir`, `postgresql-16`, `tmux`, and the Claude CLI through your package manager / npm.

You'll also need:
- An **Anthropic API key** (model calls)
- A **GitHub personal access token** with `repo` + `pull_requests` scopes (branch push + PR creation)

## 1. Clone and configure

```bash
git clone https://github.com/brinkgenesis/crucible
cd crucible
cp .env.example .env
```

Open `.env` and set at minimum:

| Var | Required? | What it does |
|---|---|---|
| `ANTHROPIC_API_KEY` | **yes** | Model calls |
| `GITHUB_TOKEN` | **yes** | Branch push + PR creation |
| `SECRET_KEY_BASE` | **yes** | Phoenix session signing. Generate with `mix phx.gen.secret` |
| `DATABASE_URL` | **yes** | Postgres connection — the native default `postgresql://localhost:5432/crucible` works with a Homebrew Postgres out of the box |
| `SANDBOX_MODE` | no (default `local`) | Set to `docker` for real container isolation on production workloads |

The rest of `.env.example` is optional — set them when you want the corresponding feature (budget limits, alerting, OTel export, OAuth, clustering, extra model providers).

## 2. Boot

```bash
mix deps.get
mix ecto.setup              # creates DB + runs migrations
mix phx.server              # (or: iex -S mix phx.server)
```

You'll see `Running CrucibleWeb.Endpoint with Bandit ... at :::4801 (http)` — that's the "stack is up" signal.

## 3. Verify

```bash
curl http://localhost:4801/api/health/live
# => {"status":"ok","timestamp":"..."}

open http://localhost:4801
```

The kanban UI loads. The main pages:
- **Dashboard** — budgets, runs, health
- **Kanban** — cards and columns (this is where work happens)
- **Runs** — live trace view of in-flight runs
- **Cost / Tokens** — aggregated spend by day / model / workflow
- **Control** — spawn interactive Claude Code sessions side-by-side (native-only feature)
- **Workspaces** — register the repos Crucible is allowed to modify

## 4. Register a workspace

Go to `/workspaces` → **New workspace**. Minimum fields:

| Field | Example |
|---|---|
| Name | `My blog` |
| Slug | `my-blog` |
| Repo path | `/Users/you/code/my-blog` (absolute path to a local clone) |

The repo must be a real git clone on disk that the Crucible process can write to.

## 5. Create your first card

1. Go to **Kanban** → **+ New card**.
2. Give it a title (e.g. *"Fix the broken test in `foo_test.exs`"*).
3. Open the card, pick the workspace from step 4, and pick a workflow. `simple-sprint` is the lightest — one coder, one PR.
4. Drag the card into **To Do** — this triggers the run.

Crucible will:
1. Generate a plan via the model router
2. Create an isolated git branch in the workspace
3. Run the coder phase (watch it live in `/runs/<run_id>/traces`)
4. Open a PR against the workspace's default branch
5. Let the PR shepherd monitor CI and respond to review comments

## Using Docker for Postgres only (optional)

If you don't want to install Postgres natively:

```bash
docker compose up -d postgres
```

Then in `.env`:

```bash
DATABASE_URL=postgresql://crucible:crucible@localhost:55432/crucible
```

Host port is `55432` to avoid clashing with a native Postgres on `5432`. The rest of the stack still runs natively via `mix phx.server`.

## Common first-run snags

- **`ANTHROPIC_API_KEY` missing** — model calls fail with 401. The health endpoint still works; runs won't.
- **`GITHUB_TOKEN` missing or scope-less** — runs execute locally but the PR phase fails. Token needs `repo` + `pull_requests` scopes.
- **`claude: command not found` in Control panel banner** — install the Claude CLI: `npm install -g @anthropic-ai/claude-code`.
- **`tmux: command not found`** — `brew install tmux` (or your distro's package).
- **Port `:5432` already allocated** when using Docker Postgres — set `POSTGRES_HOST_PORT` in `.env` to a free port.
- **Sandbox warning at startup** — `sandbox_enabled=true but SANDBOX_MODE=local` is expected on the default path. Set `SANDBOX_MODE=docker` when you want real isolation. See the README [Troubleshooting → Sandbox not isolating](../README.md#sandbox-not-isolating) section.

## Where to go next

- [Workflows guide](workflows.md) — how to pick a workflow, how phases compose, how to add your own
- [Self-improvement guide](self-improvement.md) — what the loop actually learns, how to read KPI snapshots, how to override a bad policy change
- [ARCHITECTURE.md](../ARCHITECTURE.md) — the 12-layer harness, supervision tree, adapter registry
- [CONTRIBUTING.md](../CONTRIBUTING.md) — dev setup, precommit, conventions
