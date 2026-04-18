# Crucible

**A self-improving kanban for concurrent AI agents.**

Drop a task on the board, Crucible runs it on an isolated git branch, ships a PR, and tunes its own prompts from what it learned.

> Status: pre-1.0, extracted from an internal production system and preparing for an open-source release. The code is already Apache 2.0 licensed; this repo is the public-ready fork. Public launch blocked only on the checklist below.

## What it is

- **Kanban UI** — cards move through columns; each card is a unit of work
- **Concurrent agent runs** — multiple cards execute in parallel, each in its own git worktree
- **Pluggable execution adapters** — Claude Agent SDK, direct Anthropic API, future Codex / OpenAI / self-hosted models via the same interface
- **Self-improving** — every run emits KPIs; the system tunes phase prompts and routing policies from regressions and wins
- **Built-in observability** — cost dashboard, trace viewer, circuit-breaker state, budget tracking

## What it isn't

- A hosted service. You run it yourself.
- A general agent framework (LangGraph, CrewAI). Crucible is opinionated about the shape of work: card → plan → branch → commit → PR.
- A single-model tool. The router and adapter layer are model-agnostic.

## Architecture (one picture)

```
Browser → Phoenix LiveView (kanban/cost/traces/control)
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

Postgres backs cards, runs, trace events, KPIs, policies, workspaces.

## Quickstart

> Works end-to-end today; the "coming" parts are seed data and a first-run wizard (see [Status](#status)).

```bash
git clone <repo>
cd crucible
cp .env.example .env        # set ANTHROPIC_API_KEY, GITHUB_TOKEN, DATABASE_URL
docker compose up
open http://localhost:4801
```

**For real container isolation** (recommended for production-like testing):
```bash
SANDBOX_MODE=docker docker compose up
```

**Run tests locally:**
```bash
mix deps.get
mix ecto.setup
mix test                    # 1400+ tests, ~10s
mix test --include docker   # includes sandbox integration tests (requires Docker)
mix sobelow --config        # security lint
```

## Status

Port complete; public release blocked on a short list of polish items.

- [x] Elixir core port (1400+ tests passing, 3 rounds of adversarial hardening)
- [x] LiveView UI port (kanban, cost, traces, control panel)
- [x] SDK bridge port (`Crucible.Adapter.SdkPort`, supervised)
- [x] Router bundled (see `router/`)
- [x] Docker Compose scaffold
- [x] Adapter registry documented ([ARCHITECTURE.md](ARCHITECTURE.md#adapter-registry))
- [x] Secrets provider abstraction (env + AWS Secrets Manager)
- [x] Sandbox isolation path (enabled by default; needs `SANDBOX_MODE=docker` for real containers)
- [x] Security lint wired (`mix sobelow --config`)
- [x] Migrations consolidated into a single initial schema
- [x] First-boot smoke (`docker compose up` → green dashboard) verified on a fresh clone
- [x] Docs: [quickstart](docs/quickstart.md), [workflows guide](docs/workflows.md), [self-improvement guide](docs/self-improvement.md)
- [x] CONTRIBUTING.md + issue templates
- [ ] Public launch

## Open-source release

Crucible is Apache 2.0 and being prepared for public release so anyone can self-host it as a personal or team agent runner. Before the launch flip, the priorities are:

1. **Quickstart that works on a fresh laptop** — `git clone` → `docker compose up` → working kanban. Currently the scaffold is there; the last mile is documentation, seed data, and a first-run wizard.
2. **Decouple from Till-internal workspaces** — workspace defaults still assume the maintainer's local repo layout; they need to be config-driven.
3. **Contributor ergonomics** — CONTRIBUTING.md, clear module boundaries in ARCHITECTURE.md (in progress), a good-first-issue label.

If you're reading this pre-launch and want to try it: clone, read [ARCHITECTURE.md](ARCHITECTURE.md), expect rough edges, and open issues. Contributions welcome once the CONTRIBUTING guide lands.

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
Requires a reachable Docker daemon. The `ExternalCircuitBreaker` wraps `docker run`; if Docker disappears mid-run, the breaker opens after 5 failures and the manager automatically falls back to `LocalProvider` (with a warning log).

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

**AWS fallback:** If `AWS_SECRETS_ARN` is set, `Crucible.Secrets` fetches the JSON bundle from AWS Secrets Manager at boot and injects values into the process env. If that call fails and no local env vars are present, the app will log the error and exit rather than start with missing credentials.

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

## License

Apache 2.0. See [LICENSE](LICENSE).
