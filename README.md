# Crucible

[![CI](https://github.com/brinkgenesis/crucible/actions/workflows/ci.yml/badge.svg)](https://github.com/brinkgenesis/crucible/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.15%2B-4B275F?logo=elixir)](https://elixir-lang.org/)
[![Phoenix](https://img.shields.io/badge/Phoenix-1.8-orange?logo=phoenixframework)](https://www.phoenixframework.org/)

**A self-improving kanban for concurrent AI coding agents.**

Drop a task on the board. Crucible plans it, runs it on an isolated git branch with a Claude Code agent, opens a PR, and tunes its own prompts from what it learned on the way.

## The idea

You read a lot. You save a lot. Your bookmarks, your "I should try this", your half-formed TODOs outpace your ability to actually execute on them. Crucible closes that gap: it's the runway between *"interesting link"* and *"merged PR"*.

The loop:

```
  bookmark / link / idea  ─┐
  manual card  ────────────┼──▶  inbox  ──▶  kanban card  ──▶  plan  ──▶  agent runs on git branch  ──▶  PR
  run failure  ────────────┘                                                     │
                                                                                 ▼
                                                              KPIs → prompt tuning → better next run
```

You can start cards by hand (works today) or pipe bookmarks / RSS / issues into the **inbox**, which evaluates each item with an LLM and auto-promotes the high-scoring ones to cards. Everything past the card is the same flow.

## What it is

- **Kanban UI** — cards move through columns; each card is a unit of work
- **Concurrent agent runs** — multiple cards execute in parallel, each in its own git worktree
- **Inbox + auto-triage** — external events (bookmarks, failures, etc.) land in an inbox; an LLM scores them and the good ones become cards
- **Pluggable execution adapters** — Claude Agent SDK, direct Anthropic API, future Codex / OpenAI / self-hosted models via the same interface
- **Self-improving** — every run emits KPIs; the system tunes phase prompts and routing policies from regressions and wins
- **Built-in observability** — cost dashboard, trace viewer, circuit-breaker state, budget tracking

## What it isn't

- A hosted service. You run it yourself.
- A general agent framework (LangGraph, CrewAI). Crucible is opinionated: card → plan → branch → commit → PR.
- A single-model tool. Router and adapter layers are model-agnostic.

---

## Why Elixir for agent orchestration

Crucible runs on the BEAM (Erlang virtual machine) via Elixir and Phoenix. The BEAM was built for telecom switches that couldn't go down — it's been battle-tested for decades on systems with nine-nines uptime requirements — and almost every property that made it good at routing phone calls makes it good at orchestrating swarms of AI agents.

- **Massive concurrency, cheaply.** Each agent run, each phase, each sandbox watchdog, each WebSocket push is its own BEAM process. Processes are lightweight (kilobytes, not megabytes) — a single node handles **hundreds of thousands to millions** of them without breaking a sweat. There is no thread-pool to tune and no `async/await` coloring to fight.

- **Fault isolation by default.** A process crash is contained to that process and its supervised subtree. When an agent run gets stuck in a runaway loop, hits an OOM condition in a sandbox, or a model call goes sideways, the blast radius stops there — the kanban board, the budget tracker, the trace stream, and every other in-flight run keep humming. Crucible leans on this directly: every `RunServer` sits under a `DynamicSupervisor`, and each tier has its own crash semantics and restart strategy.

- **Supervision trees + "let it crash".** Instead of defensive try/catch at every layer, faulty processes die and supervisors bring them back in a known-good state. This is the opposite of the "wrap everything in retries" pattern you see in Python/JS agent frameworks — and it's dramatically more reliable for long-running workloads that touch flaky external APIs.

- **Partition tolerance and recoverability.** Agent workloads are partition-prone by nature: models time out, git hangs, Claude's API returns 529s. The BEAM's `:gen_server` timeouts, `Task.async_stream` with explicit deadlines, and per-process mailboxes let Crucible degrade gracefully under Byzantine-style failures — slow, silent, or lying components don't stall the rest of the system. Crucible's circuit breakers and budget-paused states fall out of these primitives directly rather than being bolted on.

- **First-class distribution.** `:pg` groups, `:global`, and `Node.spawn` mean multi-node orchestration is part of the standard library. When we're ready to shard runs across machines, we don't rewrite — we add nodes.

- **Soft-realtime scheduling.** Per-process garbage collection means no stop-the-world GC pauses freezing the dashboard when one run allocates 500 MB of traces. The Control panel's live trace stream, budget meters, and phase indicators stay responsive even under heavy agent load.

- **Phoenix LiveView.** Real-time dashboards (kanban, trace viewer, cost charts, circuit-breaker state) without shipping a JS SPA, without WebSocket plumbing, without a separate API layer. Server renders a diff, browser applies it. When you're running many agents at once and want to *watch* them work, this matters a lot.

- **Pattern matching + immutable data.** Agent state flows through well-typed `Run` / `Phase` / `WorkUnit` structs. The compiler catches most "I forgot to update this call site" bugs before the test suite even runs.

If you've looked at an agent framework written in Python and thought *"this is going to be a nightmare to keep alive under production load"* — that's the problem the BEAM solves by construction.

---

## Quickstart

Crucible runs **natively** — it shells out to `claude`, `tmux`, and `git` on your machine, and the Control panel spawns real terminals you can see. Running Crucible itself inside Docker hides those tools from the app, so agent runs fail and Control does nothing. **Don't do that.** Use Docker only for Postgres if you don't already have one.

### 1. Install prerequisites

**Required versions:** Elixir 1.15+ (OTP 26+), Node.js 20+, PostgreSQL 14+.

macOS (Homebrew):
```bash
brew install elixir postgresql@16 tmux node@20
brew services start postgresql@16

# Claude CLI (needed for agent runs + Control panel)
npm install -g @anthropic-ai/claude-code
claude --version   # verify
```

Linux: use your package manager for `elixir` (1.15+), `postgresql-16`, `nodejs` (20+), and `tmux`; install the Claude CLI the same way.

### 2. Clone and configure

```bash
git clone https://github.com/brinkgenesis/crucible
cd crucible
cp .env.example .env
```

Edit `.env` — only four values are required to boot:

```bash
ANTHROPIC_API_KEY=sk-ant-...
GITHUB_TOKEN=ghp_...                              # scopes: repo, pull_requests
SECRET_KEY_BASE=...                               # run: mix phx.gen.secret
DATABASE_URL=postgresql://localhost:5432/crucible # native Postgres default
```

> **Using Docker for Postgres instead?** Run `docker compose up -d postgres` and set `DATABASE_URL=postgresql://crucible:crucible@localhost:55432/crucible`. Port is `55432` on the host to avoid colliding with a native Postgres on `5432`.

> **Postgres role needs `CREATEDB`.** `mix ecto.setup` creates the database, so the role in `DATABASE_URL` must be able to `CREATE DATABASE`. The default brew setup grants this to your OS user automatically. If you're pointing at a pre-existing role, run `ALTER USER <role> CREATEDB;` as a superuser first, or `createdb <dbname>` by hand and use `mix ecto.migrate` instead of `mix ecto.setup`.

### 3. Boot

```bash
mix deps.get
mix ecto.setup                    # creates DB, runs migrations
(cd bridge && npm install)        # SDK port bridge (Node subprocess)
mix phx.server
open http://localhost:4801
```

You should see an empty kanban. To run your first card end-to-end you need a **workspace** (which repo the agent is allowed to modify). See [First card](#first-card) below.

### Running the tests

```bash
mix test                       # ~1400 tests, ~45s
mix test --include docker      # adds sandbox integration tests (requires Docker)
mix test --include claude_cli  # adds ControlSession tests (requires `claude` and `tmux` on PATH)
mix sobelow --config           # security lint
```

### Running the whole stack in containers

There's a `docker-compose.yml` that builds a Crucible image and runs the app + Postgres. It's meant for **server self-hosting**, not local development — inside a container the app can't see your `claude` CLI, `tmux`, workspace repos on your host disk, or your GitHub SSH keys, so Control and agent runs won't work without extra wiring (bind-mounts, baking `claude` into the image, forwarding credentials). If you want that mode, see [`docs/deployment-runbook.md`](docs/deployment-runbook.md).

---

## First card

Crucible runs agents against **workspaces** — repos you've registered and given it permission to modify. Every card picks one workspace; the agent clones it into a git worktree and works there.

### 1. Register a workspace

Go to `http://localhost:4801/workspaces` → **New workspace**.

| Field | Required | Example |
|---|---|---|
| Name | yes | `My blog` |
| Slug | yes, unique | `my-blog` |
| Repo path | yes, absolute | `/Users/you/code/my-blog` |
| Default branch | no (defaults to `main`) | `main` |
| Default workflow | no (defaults to `coding-sprint`) | `simple-sprint` |
| Tech context | no | `"Next.js 15, Tailwind, MDX posts"` — injected into every agent prompt for this workspace |

The repo must be a real git clone on disk that the Crucible process can write to. Docker Compose mounts `$HOME` into the container by default — if you run with a different layout, adjust `docker-compose.yml`.

### 2. Create a card

Go to `/kanban` → **+ New card**. Title is the only required field (e.g. *"Add dark mode toggle to the navbar"*).

The card lands in the **Unassigned** column. Open it and:

- Pick the **workspace** (from step 1)
- Pick a **workflow** (see table below)
- Optionally add a longer **description** — anything you'd tell a contractor goes here

### 3. Move it to **To Do**

Dragging a card into **To Do** triggers the run. You'll see it advance through the workflow's phases on the board, with the live trace at `/runs/<run_id>/traces` and cost accumulating on `/cost`.

On success: the agent pushes a branch and opens a PR against the workspace's default branch. On failure: the card moves to **Failed**, the trace has the full story, and an inbox item is created so the failure doesn't fall through the cracks.

---

## Workflows

Nine workflows ship in [`workflows/`](workflows/). Pick per-card or per-workspace.

| Workflow | When to use |
|---|---|
| `simple-sprint` | Small, single-file changes. One coder, one PR. |
| `coding-sprint` *(default)* | Parallel three-coder worktree sprint with PR shepherd. Good general-purpose default. |
| `dual-coder-sprint` | Two coders working on partitioned file sets. |
| `reviewed-sprint` | Adds a preflight check and a parallel design review gate before coding starts. |
| `code-review` | No new code — just a reviewer pass on an existing branch. |
| `design-review` | Multi-specialist architectural review, no code changes. |
| `bug-hunt` | Researcher forms a hypothesis, then a coder tries a fix. No auto-merge. |
| `bug-hunt-parallel` | Three researchers (code / infra / data) in parallel, then a coder. |
| `repo-optimize` | Architect drafts a strategy, optimizer implements, reviewer signs off. |

See [`docs/workflows.md`](docs/workflows.md) for the phase definitions, what each role does, and how to author a custom workflow.

---

## The inbox (bookmarks, links, failures)

Crucible has an **inbox** for things that *might* become cards. An item in the inbox is evaluated by an LLM against a scoring rubric; items that score above threshold are auto-promoted to cards on a 3-hour Oban schedule.

All six sources are wired end-to-end:

| Source | How it fires | Config |
|---|---|---|
| `link` | `POST /api/v1/inbox/link` (session-authed) with `{"url": "..."}` — optionally fetches `<title>` | none |
| `rss` | `Crucible.Jobs.RssIngestJob` polls every 30 min | `INBOX_RSS_FEEDS` (comma-separated feed URLs) |
| `github` | `Crucible.Jobs.GithubIngestJob` polls issues + PRs every 2h | `GITHUB_OWNER`, `GITHUB_REPO`, `GITHUB_TOKEN` |
| `webhook` | `POST /api/v1/webhooks/inbox/receive` with HMAC-SHA256 signature | `INBOX_WEBHOOK_SECRET` (unset = unsigned dev mode) |
| `manual` | `Crucible.Inbox.upsert_from_ingestion/1` from your own code | none |
| `run_failure` | Automatic — a failed workflow run files itself | none |

The triage/scan/promote pipeline lives in `lib/crucible/inbox/scanner.ex` and runs on a 3-hour Oban schedule. Dedup is handled by the unique index on `(source, source_id)`, so re-polling any source is idempotent.

**Webhook example:**

```bash
body='{"source_id":"blog-post-42","title":"Found on Hacker News","url":"https://news.ycombinator.com/item?id=42"}'
sig=$(echo -n "$body" | openssl dgst -sha256 -hmac "$INBOX_WEBHOOK_SECRET" -hex | awk '{print $2}')

curl -X POST http://localhost:4801/api/v1/webhooks/inbox/receive \
  -H "content-type: application/json" \
  -H "x-crucible-signature-256: sha256=$sig" \
  -d "$body"
```

**If you don't use bookmarks at all:** everything works without any ingester configured. Manual card creation is the primary path.

---

## Environment variables

Only the **Required** rows are needed to boot. The rest unlock optional features.

### Required

| Var | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | Claude model access |
| `GITHUB_TOKEN` | Branch push + PR creation. Scopes: `repo`, `pull_requests` |
| `SECRET_KEY_BASE` | Phoenix session signing. Generate: `openssl rand -base64 48` |
| `DATABASE_URL` | Postgres. Default in `.env.example` matches `docker-compose.yml` |

### Optional — model providers

`GOOGLE_API_KEY` (Gemini) · `OPENAI_API_KEY` · `OPENROUTER_API_KEY` · `TOGETHER_API_KEY` · `MINIMAX_API_KEY` · `OLLAMA_BASE_URL` (local fallback). The router picks between configured providers by tier; unset providers are simply skipped.

### Optional — GitHub defaults

`GITHUB_OWNER`, `GITHUB_REPO` — used by the CI log ingestor and as fallbacks when a card doesn't specify a workspace.

### Optional — sandbox (workload isolation)

| Var | Default | What it does |
|---|---|---|
| `SANDBOX_ENABLED` | `true` | Activate the sandbox code path |
| `SANDBOX_MODE` | `local` | `local` (no isolation) or `docker` (real containers) |
| `SANDBOX_POOL_SIZE` | `3` | Warm container count |
| `SANDBOX_IMAGE` | `node:22-alpine` | Base image |
| `SANDBOX_POLICY` | `standard` | `strict` / `standard` / `permissive` |

For production workloads use `SANDBOX_MODE=docker`. See [Sandbox not isolating](#sandbox-not-isolating) below.

### Optional — dashboard auth

If you leave `DASHBOARD_AUTH=false`, treat the UI as a localhost or private-network operator surface only. Do not expose it directly to the public internet without putting auth in front of it.

| Var | Purpose |
|---|---|
| `DASHBOARD_AUTH` | Set `true` to require Google OAuth on the UI |
| `GOOGLE_OAUTH_CLIENT_ID` / `GOOGLE_OAUTH_CLIENT_SECRET` | From Google Cloud Console |
| `OAUTH_ALLOWED_DOMAIN` | Restrict to one GSuite domain (omit for open sign-in) |

### Optional — budgets, alerting, observability

`DAILY_BUDGET_LIMIT_USD`, `AGENT_BUDGET_LIMIT_USD`, `TASK_BUDGET_LIMIT_USD`, `ALERT_WEBHOOK_URL`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `SENTRY_DSN`. Full list in [`.env.example`](.env.example).

---

## Architecture

```
Browser → Phoenix LiveView (kanban / cost / traces / control / workspaces)
              ↓
         Elixir core (GenServer supervision tree)
              ↓
  ┌───────────┴───────────┐
  │                       │
SDK adapter        API adapter       (… more adapters)
  │                       │
Node subprocess       HTTP client
  │                       │
Claude Agent SDK    Anthropic / OpenAI / …
              ↓
       Git worktrees (isolated branches)
              ↓
           GitHub PRs
```

Postgres backs cards, runs, trace events, KPIs, policies, workspaces, and inbox items.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the 12-layer harness, adapter registry, and phase runner details. [`docs/self-improvement.md`](docs/self-improvement.md) covers how KPIs flow back into prompt tuning.

---

## Troubleshooting

### Circuit breaker open

**What triggers it:** Three consecutive failures from a provider (Anthropic API 5xx, timeout, or SDK bridge crash) trip the circuit breaker for that provider. All adapter calls short-circuit immediately until the breaker recovers.

**Check state:**
```elixir
Crucible.ExternalCircuitBreaker.status()
# => %{anthropic: :open, openai: :closed}
```

**Reset:** The breaker moves to `:half_open` automatically after the configured cooldown (default 60s). One probe request is sent; success closes it, failure reopens it. To force a reset without waiting, restart the `Crucible.ExternalCircuitBreaker` process:
```elixir
Supervisor.terminate_child(Crucible.Supervisor, Crucible.ExternalCircuitBreaker)
Supervisor.restart_child(Crucible.Supervisor, Crucible.ExternalCircuitBreaker)
```

---

### Sandbox not isolating

**Two knobs, both required for real isolation:**

| Setting | Default | What it does |
|---|---|---|
| `sandbox_enabled` feature flag | `true` | Activates the sandbox code path |
| `SANDBOX_MODE` env var | `local` | Picks the provider — `local` (no isolation) or `docker` (real containers) |

With the defaults, the sandbox code path runs but uses `LocalProvider` — which is **not real isolation**. At startup you'll see:
```
[warning] Sandbox.Manager: sandbox_enabled=true but SANDBOX_MODE=local — no real container isolation. Set SANDBOX_MODE=docker for production workloads.
```

**Enable real isolation:**
```bash
SANDBOX_MODE=docker mix phx.server
```
Requires a reachable Docker daemon. The `ExternalCircuitBreaker` wraps `docker run`; if Docker becomes unavailable, Docker-mode acquisitions fail closed until the daemon recovers.

**Disable entirely:**
```bash
SANDBOX_ENABLED=false mix phx.server
```

**When to disable:** Local development with workflows that rely on host-side tools (git, npm, native binaries) not present in the sandbox image. Control scope via workspace permission profiles instead.

**Test env:** Always `sandbox_enabled: false`. Docker-requiring tests opt in via `@tag :docker` and `mix test --include docker`.

---

### Run stuck / phase timeout

**Where to look:**
- Cold trace log: `traces/<run_id>.jsonl` — look for the last event before silence.
- Oban dashboard (available at `/admin/oban` if `oban_web` is in deps) — check for retrying or discarded jobs.
- Live trace viewer: `http://localhost:4801/runs/<run_id>/traces`.

**Log grep:**
```bash
grep "phase_timeout\|stuck\|circuit" .crucible/logs/crucible.log | tail -30
```

**Manually kill a stuck run:**
```elixir
# Find the RunServer pid
pid = Crucible.Registry.lookup(:run, "<run_id>")
# Graceful shutdown (triggers cleanup)
GenServer.stop(pid, :shutdown)
```
Then mark the card as failed on the kanban board to unblock the queue.

---

### Secrets bootstrap failed

**Symptoms at startup:** Lines like `[error] Secrets: failed to fetch from AWS` followed by missing env vars causing downstream crashes (DB connection failure, Anthropic 401, GitHub 403).

**Required env vars (minimum viable startup):**

| Var | Purpose |
|-----|---------|
| `ANTHROPIC_API_KEY` | Model calls |
| `DATABASE_URL` | Postgres connection |
| `GITHUB_TOKEN` | Branch push + PR creation |
| `SECRET_KEY_BASE` | Phoenix session signing |

**AWS fallback:** If `SECRETS_PROVIDER=aws` and `AWS_SECRET_NAME` are set, `Crucible.Secrets` fetches the JSON bundle from AWS Secrets Manager at boot and serves reads from its in-memory cache. If that call fails and no local env vars are present, the app exits rather than starting with missing credentials.

**Fix:** Either set the vars directly in `.env` / your deployment environment, or verify the EC2 instance role has `secretsmanager:GetSecretValue` on the ARN.

---

### Log markers — grep patterns

| What to find | Pattern |
|---|---|
| Session start/end | `grep "ControlSession:"` |
| Phase transitions | `grep "PhaseRunner:"` |
| Run dispatch | `grep "Orchestrator: dispatching run"` |
| Circuit state change | `grep "circuit_breaker"` |
| Budget exceeded | `grep "budget.*exceeded\|over.*budget"` |
| Error with run ID | `grep "run_id=<id>"` |

Trace files follow this naming convention: `traces/<run_id>.jsonl`. Each line is a JSON object with `event`, `phase_id`, `timestamp`, and (for tool calls) `tool_name` and `input`.

---

## Docs

- [`docs/quickstart.md`](docs/quickstart.md) — step-by-step first run
- [`docs/workflows.md`](docs/workflows.md) — phases, roles, authoring a custom workflow
- [`docs/self-improvement.md`](docs/self-improvement.md) — KPIs, policy tuning, intervention
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — supervision tree, adapters, harness layers
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — dev setup, testing, PR process

## License

Apache 2.0. See [LICENSE](LICENSE).
