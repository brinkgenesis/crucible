# InfraOrchestrator

Elixir/Phoenix control plane for the agentic orchestration platform. Manages workflow runs, budget tracking, kanban boards, research projects, and provides a real-time LiveView dashboard.

## Architecture

- **Orchestrator GenServer** — polls for pending runs, dispatches to per-run `RunServer` processes via `DynamicSupervisor`
- **Budget Tracker** — 3-tier cost control (daily/agent/task) backed by ETS for fast concurrent reads
- **Circuit Breakers** — per-workflow circuit breakers with cooldown, pruning, and half-open canary logic
- **Multi-tenant** — per-tenant process trees with scoped budget tracking and run isolation
- **Distributed** — optional gossip-based clustering with cross-node run discovery via `:pg`
- **Benchmark Autopilot** — auto-ingests terminal workflow runs into `experiment_runs`, establishes baselines, and creates vault-backed improvement cards
- **Execution Modes** — Phoenix Kanban can trigger runs in `Teams` (`subscription`) or `API` mode, matching the TypeScript dashboard toggle and persisting the selection in the browser
- **Research Benchmark Lane** — Harbor / Terminal-Bench runs ingest into a separate `research_benchmark` lane so verifier-backed benchmark evidence does not pollute workflow-learning experiments
- **Phoenix Kanban Plans** — cards can carry `planSummary`, `planNote`, and `planWikiLink` metadata with inline vault-plan previews in LiveView

For the dedicated Phoenix/Elixir architecture, see [ARCHITECTURE.md](/Users/helios/infra/orchestrator/ARCHITECTURE.md).

## Automatic Benchmark Loop

Phoenix now runs two native benchmark loops with different evidence standards:

1. `SelfImprovement` observes a completed workflow run.
2. `BenchmarkAutopilot` reads run timing from traces, token usage from transcripts, and spend from cost events.
3. The run is inserted into the benchmark publication domain as a workflow-learning `experiment_run`.
4. Regressions, failed runs, and inefficient new bests create Kanban cards automatically.
5. Each suggestion writes a detailed markdown plan into `memory/decisions/` and links it back to the card metadata.
6. Separately, Harbor / Terminal-Bench summaries are ingested into the `research_benchmark` lane and stay isolated from workflow-learning evidence.

This means the dashboard is no longer just showing self-improvement signals; it is generating concrete follow-up work from workflow evidence while preserving a stricter research-grade benchmark lane for external evals.

## Execution Mode Toggle

Phoenix now mirrors the TypeScript execution toggle for Kanban-triggered workflows:

- `Teams`
  - uses the existing subscription / free-form agent-team execution path
- `API`
  - sets `execution_type=api` on the workflow manifest for API-first execution paths

The toggle lives in the shared sidebar, persists in browser storage, and is read by the Phoenix Kanban board and Kanban API trigger path.

## Quick Start

```bash
# Install dependencies
mix setup

# Start the server (port 4801)
mix phx.server

# Or with IEx
iex -S mix phx.server
```

Visit [localhost:4801](http://localhost:4801) for the LiveView dashboard.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | (dev config) | PostgreSQL connection string |
| `SECRET_KEY_BASE` | (generated) | Phoenix secret for sessions |
| `PHX_PORT` | `4801` | HTTP port |
| `PHX_HOST` | `localhost` | Hostname for URL generation |
| `INFRA_API_KEY` | (none) | API authentication key (required in prod) |
| `DAILY_BUDGET_LIMIT_USD` | `100` | Daily cost budget |
| `AGENT_BUDGET_LIMIT_USD` | `10` | Per-agent cost limit |
| `TASK_BUDGET_LIMIT_USD` | `50` | Per-task cost limit |
| `CLUSTER_GOSSIP_SECRET` | (required for gossip) | Cluster authentication secret |
| `SECRETS_PROVIDER` | `env` | Secrets backend: `env` (default) or `aws` (Secrets Manager) |
| `AWS_SECRET_NAME` | (none) | AWS Secrets Manager secret name (when `SECRETS_PROVIDER=aws`) |
| `AWS_REGION` | `us-east-1` | AWS region (when `SECRETS_PROVIDER=aws`) |
| `SANDBOX_MODE` | `local` | Sandbox backend: `local` (no-op) or `docker` (real isolation) |
| `SANDBOX_POOL_SIZE` | `3` | Number of pre-warmed sandbox containers |
| `SANDBOX_IMAGE` | `node:22-alpine` | Docker image for sandbox containers |
| `SANDBOX_POLICY` | `standard` | Default policy: `strict`, `standard`, `permissive` |
| `SANDBOX_ROUTER_HOST` | `host.docker.internal:4800` | Router endpoint allowed in sandbox network |
| `ALERTING_ENABLED` | `false` | Enable alert processing (set `true` in production) |
| `ALERT_WEBHOOK_URL` | (none) | Outbound webhook URL for notifications |
| `ALERT_WEBHOOK_FORMAT` | `generic` | Outbound format: generic, slack, discord, pagerduty, teams |
| `ALERT_COOLDOWN_MS` | `300000` | Minimum interval between duplicate alerts (ms) |

## API

### Versioning

API routes are versioned under `/api/v1`. Unversioned `/api` routes remain for backward compatibility but will be removed in a future release.

### Authentication

- **API key**: Set via `INFRA_API_KEY` env var, passed as `Authorization: Bearer <key>`
- **Session auth**: OAuth-based sessions shared with the TypeScript dashboard

### Key Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /api/health/{live,ready,startup}` | Kubernetes health probes (no auth) |
| `GET /api/v1/health` | Full system health with budget and run summary |
| `GET /api/v1/runs` | List workflow runs (paginated) |
| `GET /api/v1/kanban/cards` | Kanban board cards |
| `GET /api/v1/budget/status` | Current budget status |
| `GET /api/v1/research/projects` | Research projects with scores (paginated) |
| `POST /api/v1/webhooks/alert` | Inbound Alertmanager webhook (no auth) |
| `GET /api/v1/config` | System configuration |
| `GET /api/openapi` | OpenAPI 3.0 spec |
| `GET /api/docs` | Swagger UI |

All list endpoints support `?limit=N&offset=M` pagination (max 200 per page).

## Testing

```bash
# Run all tests (722+ tests, 21 properties)
mix test

# Run with coverage
mix test --cover

# Specific test files
mix test test/infra_orchestrator_web/api/
```

## Deployment

Requires Erlang/OTP 28+ and Elixir 1.19+. Uses `mix release` for production builds.

```bash
MIX_ENV=prod mix release
_build/prod/rel/infra_orchestrator/bin/infra_orchestrator start
```

### Kubernetes

Health probes are Kubernetes-compatible:
- **Liveness**: `GET /api/health/live` (BEAM responsive)
- **Readiness**: `GET /api/health/ready` (DB, Orchestrator, ETS)
- **Startup**: `GET /api/health/startup` (DB, workflows, Oban)
