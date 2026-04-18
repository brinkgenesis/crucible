# Infra Orchestrator — Deployment Runbook

Production deployment guide for the Elixir/Phoenix orchestrator (`infra_orchestrator`).

---

## Prerequisites

| Component   | Version            | Notes                                          |
|-------------|--------------------|-------------------------------------------------|
| Elixir      | ~> 1.15            | OTP 26+ recommended                            |
| Erlang/OTP  | 26.2+              | Required for Mnesia disc_copies and IPv6 dist   |
| PostgreSQL  | 14+                | Primary data store (Ecto)                       |
| Node.js     | 18+ (build only)   | esbuild/tailwind asset compilation              |
| Docker      | 24+ (optional)     | Multi-stage Dockerfile included                 |

The release is built with `mix release infra_orchestrator`. The Dockerfile uses `hexpm/elixir:1.15.7-erlang-26.2.1-debian-bookworm` as the builder image.

---

## Production Deployment Checklist

Before going live, ensure these config changes are made. All infrastructure is already built — this is just flipping env vars.

### 1. AWS Secrets Manager

Create a Secrets Manager secret (e.g. `infra-orchestrator/prod`) containing a JSON object:

```json
{
  "DATABASE_URL": "ecto://user:pass@rds-host/infra_orchestrator_prod",
  "SECRET_KEY_BASE": "<mix phx.gen.secret output>",
  "INFRA_API_KEY": "<your API key>",
  "ANTHROPIC_API_KEY": "sk-ant-...",
  "GOOGLE_API_KEY": "AIza...",
  "MINIMAX_API_KEY": "eyJ...",
  "OPENAI_API_KEY": "sk-...",
  "OPENROUTER_API_KEY": "sk-or-...",
  "TOGETHER_API_KEY": "...",
  "GOOGLE_OAUTH_CLIENT_ID": "...apps.googleusercontent.com",
  "GOOGLE_OAUTH_CLIENT_SECRET": "GOCSPX-...",
  "GITHUB_TOKEN": "ghp_...",
  "ALERT_WEBHOOK_URL": "https://hooks.slack.com/services/...",
  "CLOUDFLARE_API_TOKEN": "...",
  "CLUSTER_GOSSIP_SECRET": "<random string>"
}
```

Then set these bootstrap env vars (in ECS task definition, K8s configmap, or `.env`):

```bash
SECRETS_PROVIDER=aws
AWS_REGION=us-east-1
AWS_SECRET_NAME=infra-orchestrator/prod
```

IAM role authentication is used on ECS/EKS — no `AWS_ACCESS_KEY_ID` needed when the task role has `secretsmanager:GetSecretValue` permission.

### 2. Alerting

```bash
ALERTING_ENABLED=true
# ALERT_WEBHOOK_URL goes in Secrets Manager (above)
# ALERT_WEBHOOK_FORMAT goes as plain env var:
ALERT_WEBHOOK_FORMAT=slack   # or: generic, discord, pagerduty, teams
```

### 3. Remaining Plain Env Vars (not secrets — set in task definition or configmap)

```bash
PHX_SERVER=true
PHX_HOST=your-domain.com
PORT=4801
POOL_SIZE=20
POOL_COUNT=2
DASHBOARD_AUTH=true
OAUTH_ALLOWED_DOMAIN=your-domain.com
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318
CLUSTER_STRATEGY=k8s        # or dns
```

---

## Environment Variables

### Required (prod raises on missing)

| Variable          | Description                                | Example                                      |
|-------------------|--------------------------------------------|----------------------------------------------|
| `DATABASE_URL`    | PostgreSQL connection URL                  | `ecto://user:pass@host/infra_orchestrator_prod` |
| `SECRET_KEY_BASE` | Cookie signing/encryption key (64+ bytes)  | Generate with `mix phx.gen.secret`           |

### Server

| Variable     | Default  | Description                                              |
|--------------|----------|----------------------------------------------------------|
| `PHX_SERVER` | _(unset)_ | Set to `true` to start the HTTP server in releases       |
| `PORT`       | `4801`   | HTTP listen port                                         |
| `PHX_HOST`   | `example.com` | Public hostname (used for URL generation in prod)   |

### Database

| Variable              | Default | Description                                        |
|-----------------------|---------|----------------------------------------------------|
| `DATABASE_URL`        | _(required)_ | Full Ecto connection URL                      |
| `POOL_SIZE`           | `10`    | Number of database connections per pool              |
| `POOL_COUNT`          | `1`     | Number of connection pools                           |
| `DB_CHECKOUT_TIMEOUT` | `15000` | Max ms to wait for a connection from pool            |
| `DB_QUEUE_TARGET`     | `50`    | Target queue time (ms) before pool grows             |
| `DB_QUEUE_INTERVAL`   | `1000`  | Interval (ms) to check queue target                  |
| `ECTO_IPV6`           | _(unset)_ | Set to `true` or `1` to enable IPv6 socket options |

### Authentication

| Variable                      | Default        | Description                                  |
|-------------------------------|----------------|----------------------------------------------|
| `DASHBOARD_AUTH`              | `false`        | Set to `true` to require auth for dashboard  |
| `GOOGLE_OAUTH_CLIENT_ID`     | _(unset)_      | Google OAuth2 client ID                      |
| `GOOGLE_OAUTH_CLIENT_SECRET` | _(unset)_      | Google OAuth2 client secret                  |
| `OAUTH_ALLOWED_DOMAIN`       | `tillcfo.com`  | Restrict OAuth logins to this email domain   |

### CORS

| Variable               | Default    | Description                                       |
|------------------------|------------|---------------------------------------------------|
| `CORS_ALLOWED_ORIGINS` | _(unset)_  | Comma-separated allowed origins; unset = disabled  |

### Rate Limits

All values are requests per window.

| Variable                  | Default | Description                         |
|---------------------------|---------|-------------------------------------|
| `RATE_LIMIT_IP_READ`      | `120`   | Read requests per IP per window     |
| `RATE_LIMIT_IP_WRITE`     | `20`    | Write requests per IP per window    |
| `RATE_LIMIT_TENANT_READ`  | `300`   | Read requests per tenant per window |
| `RATE_LIMIT_TENANT_WRITE` | `60`    | Write requests per tenant per window|

### Sandbox Isolation (API Workflows)

| Variable               | Default                    | Description                                             |
|------------------------|----------------------------|---------------------------------------------------------|
| `SANDBOX_MODE`         | `local`                    | `local` (no-op passthrough) or `docker` (real isolation)|
| `SANDBOX_POOL_SIZE`    | `3`                        | Pre-warmed container pool size                          |
| `SANDBOX_IMAGE`        | `node:22-alpine`           | Docker image for sandbox containers                     |
| `SANDBOX_POLICY`       | `standard`                 | Default preset: `strict`, `standard`, `permissive`      |
| `SANDBOX_ROUTER_HOST`  | `host.docker.internal:4800`| Router endpoint allowed in sandbox network policy       |
| `SANDBOX_NETWORK_ALLOWLIST` | _(unset)_             | Comma-separated extra allowed endpoints (permissive)    |

Also requires `FeatureFlags.enable(:sandbox_enabled)` at runtime (or set in config).

**Policy presets:**
- `strict`: `--network=none`, `/sandbox` read-write only, read-only rootfs, seccomp hardened, 512MB memory
- `standard`: bridge network (router endpoint allowed), `/sandbox` + `/tmp`, seccomp hardened, 1GB memory
- `permissive`: bridge with configurable allowlist, seccomp hardened, 2GB memory

**Per-tenant override:** Set `sandbox_policy` column in `client_config` table per client. Falls back to global `SANDBOX_POLICY` if not set.

**Graceful degradation:** If Docker daemon is unavailable, the circuit breaker (`:docker_daemon`) opens and the Manager falls back to `LocalProvider` (unsandboxed execution) with an audit log entry. No workflow failures.

**Seccomp profile:** `priv/sandbox/seccomp-hardened.json` blocks `ptrace`, `mount`, `reboot`, kernel module loading, and privilege escalation syscalls. Applied automatically to all sandbox containers.

### Secrets Provider

| Variable            | Default         | Description                                           |
|---------------------|-----------------|-------------------------------------------------------|
| `SECRETS_PROVIDER`  | `env`           | Backend: `env` (System.get_env) or `aws` (Secrets Manager) |
| `AWS_SECRET_NAME`   | _(unset)_       | Secrets Manager secret name (JSON blob), e.g. `infra-orchestrator/prod` |
| `AWS_REGION`        | `us-east-1`     | AWS region for Secrets Manager API calls              |

The secrets provider is bootstrapped at the top of `config/runtime.exs` via `InfraOrchestrator.Secrets.init!/0`. It fetches all 15 sensitive keys in one batch, caches them in `:persistent_term`, and all subsequent reads are zero-cost. The `SECRETS_PROVIDER`, `AWS_REGION`, and `AWS_SECRET_NAME` vars themselves always come from env (bootstrap config — not stored in Secrets Manager).

In production with AWS: create a Secrets Manager secret containing a JSON object with keys matching env var names (e.g. `{"DATABASE_URL": "ecto://...", "SECRET_KEY_BASE": "...", ...}`). Use IAM role authentication on ECS/EKS — no access key env vars needed.

### Alerting

| Variable                  | Default   | Description                                         |
|---------------------------|-----------|-----------------------------------------------------|
| `ALERTING_ENABLED`        | `false`   | Set to `true` to enable alert processing            |
| `ALERT_WEBHOOK_URL`       | _(unset)_ | Outbound webhook URL for notifications              |
| `ALERT_WEBHOOK_FORMAT`    | `generic` | Format: `generic`, `slack`, `discord`, `pagerduty`, `teams` |
| `ALERT_COOLDOWN_MS`       | `300000`  | Minimum ms between repeated alerts (5 min default)  |
| `ALERT_BUDGET_WARNING_PCT`| `80`      | Budget usage % that triggers a warning alert        |
| `ALERT_FAILURE_RATE_PCT`  | `25`      | Failure rate % that triggers an alert               |

**Alerting architecture**: Prometheus evaluates alert rules (`monitoring/alerts/*.yml`) and fires to Alertmanager (:9093), which groups, deduplicates, and POSTs to `POST /api/v1/webhooks/alert` (no auth required — internal network only). The `AlertWebhookController` maps Alertmanager payloads to internal PubSub events, which the `AlertManager` GenServer evaluates against internal rules (cooldown dedup) and dispatches to the configured outbound webhook.

**Prometheus alert rules**:
- `cost-alerts.yml` — DailyCostWarning (>$70), DailyCostCritical (>$90), HighTokenUsage
- `run-alerts.yml` — RunFailureRate (>10%), RunStuck (>1h), RunQueueBacklog (>20 queued)
- `service-alerts.yml` — ServiceDown (2m), HighErrorRate (>5% 5xx), HighLatency (p95 >2s), BackupStale (>25h)

### Cluster

| Variable                    | Default               | Description                                      |
|-----------------------------|-----------------------|--------------------------------------------------|
| `CLUSTER_STRATEGY`          | `gossip`              | Clustering mode: `gossip`, `dns`, or `k8s`       |
| `CLUSTER_DNS_QUERY`         | _(empty)_             | DNS SRV query (required when strategy=dns)       |
| `CLUSTER_DNS_POLL_INTERVAL` | `5000`                | ms between DNS polling for node discovery        |
| `CLUSTER_NODE_BASENAME`     | `infra_orchestrator`  | Node base name for DNS-discovered nodes          |
| `CLUSTER_GOSSIP_SECRET`     | _(unset)_             | Shared secret for gossip authentication          |
| `CLUSTER_GOSSIP_PORT`       | `45892`               | UDP port for gossip protocol                     |
| `CLUSTER_K8S_NAMESPACE`     | `default`             | Kubernetes namespace for node discovery          |
| `CLUSTER_K8S_SERVICE`       | `infra-orchestrator`  | Kubernetes service name (required when strategy=k8s) |
| `CLUSTER_K8S_APP_NAME`      | `infra-orchestrator`  | Kubernetes app label for pod selection           |

### Distributed State

| Variable                   | Default | Description                                |
|----------------------------|---------|--------------------------------------------|
| `DISTRIBUTED_RPC_TIMEOUT_MS` | `3000` | Timeout for cross-node RPC calls (ms)     |

### OpenTelemetry

| Variable                       | Default                  | Description                          |
|--------------------------------|--------------------------|--------------------------------------|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4318`  | OTLP HTTP endpoint for trace export  |

### Erlang / Release

These are set in `rel/env.sh.eex` and can be overridden:

| Variable               | Default                                    | Description                          |
|------------------------|--------------------------------------------|--------------------------------------|
| `MNESIA_DIR`           | `/data/mnesia/${RELEASE_NAME}`             | Mnesia data directory (persistent)   |
| `RELEASE_DISTRIBUTION` | `name`                                     | Erlang distribution mode             |
| `RELEASE_NODE`         | `${RELEASE_NAME}@${HOSTNAME:-127.0.0.1}`  | Erlang node name                     |
| `ERL_MAX_PORTS`        | `65536`                                    | Max open ports for BEAM              |

---

## Building the Release

### From Source

```bash
export MIX_ENV=prod

mix deps.get --only prod
mix compile

# Compile assets (requires Node.js for esbuild/tailwind install)
mix assets.deploy

# Build the OTP release
mix release infra_orchestrator
```

The release is output to `_build/prod/rel/infra_orchestrator/`.

### Docker

```bash
docker build -t infra-orchestrator:latest .
```

The Dockerfile handles the full build pipeline: deps, compile, assets, release. The runner image is `debian:bookworm-slim` with `tini` as PID 1 for signal handling.

---

## Database Migrations

### Development

```bash
mix ecto.migrate
```

### Production (Mix available)

```bash
MIX_ENV=prod mix ecto.migrate
```

### Production Release (no Mix)

```bash
bin/infra_orchestrator eval "InfraOrchestrator.Release.migrate()"
```

### Rollback

```bash
bin/infra_orchestrator eval "InfraOrchestrator.Release.rollback(InfraOrchestrator.Repo, 20240101000000)"
```

Replace the version number with the target migration timestamp.

### Docker

The default Docker CMD runs migrations automatically before start:

```
sh -c "bin/infra_orchestrator eval 'InfraOrchestrator.Release.migrate()' && bin/infra_orchestrator start"
```

---

## Cluster Configuration

The orchestrator supports three clustering strategies via `CLUSTER_STRATEGY`:

### Gossip (default, development)

Nodes discover each other via UDP multicast. Suitable for local development and single-network deployments.

```bash
CLUSTER_STRATEGY=gossip
CLUSTER_GOSSIP_SECRET=my-shared-secret   # recommended for security
CLUSTER_GOSSIP_PORT=45892                # default
```

**Warning**: The ConfigValidator logs a warning if `CLUSTER_GOSSIP_SECRET` is not set.

### DNS (production)

Nodes are discovered via DNS SRV record polling. Recommended for Docker Compose / ECS / Nomad.

```bash
CLUSTER_STRATEGY=dns
CLUSTER_DNS_QUERY=infra-orchestrator.default.svc.cluster.local
CLUSTER_DNS_POLL_INTERVAL=5000
CLUSTER_NODE_BASENAME=infra_orchestrator
```

**Required**: `CLUSTER_DNS_QUERY` must be set or startup will raise.

### Kubernetes

Nodes are discovered via the Kubernetes API. Recommended for K8s deployments.

```bash
CLUSTER_STRATEGY=k8s
CLUSTER_K8S_NAMESPACE=default
CLUSTER_K8S_SERVICE=infra-orchestrator
CLUSTER_K8S_APP_NAME=infra-orchestrator
```

**Required**: `CLUSTER_K8S_SERVICE` must be set or startup will raise.

### Distributed Components

When the `:distributed` application config is `true`, the supervision tree adds:

1. **Cluster Topology** (libcluster) -- node discovery and connection
2. **Distributed Registry** (Horde) -- cluster-wide process registry
3. **Distributed Supervisor** (Horde DynamicSupervisor) -- cross-node process placement
4. **Distributed Store** (Mnesia) -- replicated workflow state (see `mnesia-backup.md`)

---

## Health Checks

All health probes are unauthenticated and located under `/api/health/`.

### Liveness -- `/api/health/live`

- **Purpose**: Confirms the BEAM VM is responsive.
- **Checks**: Returns a UTC timestamp (trivial).
- **Use**: Kubernetes `livenessProbe`. If this fails, the pod/container should be restarted.
- **Response (200)**:
  ```json
  {"status": "ok", "timestamp": "2026-03-10T12:00:00Z"}
  ```

### Readiness -- `/api/health/ready`

- **Purpose**: Confirms the application can accept traffic.
- **Checks**: Repo connection pool, Orchestrator GenServer alive, BudgetTracker ETS table exists.
- **Use**: Kubernetes `readinessProbe`. Failing nodes are removed from the load balancer.
- **Response (200 or 503)**:
  ```json
  {"status": "ok|degraded", "checks": [
    {"name": "repo", "status": "ok"},
    {"name": "orchestrator", "status": "ok"},
    {"name": "budget_ets", "status": "ok"}
  ]}
  ```

### Startup -- `/api/health/startup`

- **Purpose**: Confirms the application has fully initialized.
- **Checks**: Repo query (`SELECT 1`), WorkflowStore has loaded workflows, Oban job queue running.
- **Use**: Kubernetes `startupProbe`. Prevents traffic before initialization completes.
- **Response (200 or 503)**:
  ```json
  {"status": "ok|degraded", "checks": [
    {"name": "repo", "status": "ok"},
    {"name": "workflows", "status": "ok", "count": 5},
    {"name": "oban", "status": "ok"}
  ]}
  ```

### Full Status -- `/api/health`

- **Purpose**: Dashboard-level system health including budget and run statistics.
- **Checks**: All of the above (repo, orchestrator, budget_ets, workflows, oban) plus budget and run summaries.
- **Response (200)**:
  ```json
  {
    "status": "ok|degraded",
    "checks": [...],
    "budget": {
      "dailySpent": 12.50,
      "dailyLimit": 100.0,
      "dailyRemaining": 87.50,
      "isOverBudget": false
    },
    "runs": {
      "total": 42,
      "active": 3,
      "pending": 1,
      "failed": 2,
      "done": 36
    }
  }
  ```
  Status is `"degraded"` if any check fails OR if the budget is over limit.

### Kubernetes Probe Configuration

```yaml
livenessProbe:
  httpGet:
    path: /api/health/live
    port: 4801
  initialDelaySeconds: 5
  periodSeconds: 15
  timeoutSeconds: 5

readinessProbe:
  httpGet:
    path: /api/health/ready
    port: 4801
  initialDelaySeconds: 10
  periodSeconds: 10
  timeoutSeconds: 5

startupProbe:
  httpGet:
    path: /api/health/startup
    port: 4801
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 12
  timeoutSeconds: 5
```

Each health check has a 2-second internal timeout per individual sub-check.

### Docker HEALTHCHECK

The Dockerfile includes a built-in healthcheck:

```dockerfile
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -sf http://localhost:4801/api/health/live || exit 1
```

---

## Rolling Deploys

### Graceful Shutdown Sequence

The orchestrator is designed for zero-downtime rolling deploys:

1. **SIGTERM received** -- `tini` (PID 1 in Docker) forwards the signal to the BEAM.
2. **`prep_stop/1` callback** -- Drains Oban job queues (`default` and `patrol`) with `with_safety: true`, ensuring in-progress jobs complete but no new jobs are dequeued.
3. **Endpoint drainer** -- The Phoenix endpoint drainer allows up to **30 seconds** (`shutdown: 30_000`) for in-flight HTTP requests and WebSocket connections to complete.
4. **Supervision tree shutdown** -- All child processes terminate in reverse start order.

### Deploy Checklist

1. **Run migrations first** (if any):
   ```bash
   bin/infra_orchestrator eval "InfraOrchestrator.Release.migrate()"
   ```
   Migrations are forward-compatible -- deploy the new code, run migrations, then restart. Rollback migrations separately if needed.

2. **Roll new instances** with health checks gating traffic:
   - Wait for `/api/health/startup` to return 200 before sending traffic.
   - Wait for `/api/health/ready` to return 200 before adding to load balancer.

3. **Drain old instances**:
   - Send SIGTERM.
   - Wait up to 35 seconds (30s drain + 5s buffer) before force-killing.

4. **Verify post-deploy**:
   - Check `/api/health` on all nodes for `"status": "ok"`.
   - Verify Oban queues are processing: check the `oban_jobs` table for stuck jobs.
   - Confirm cluster membership: nodes should auto-discover via libcluster.

### Kubernetes Rolling Update

```yaml
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    spec:
      terminationGracePeriodSeconds: 45
```

Set `terminationGracePeriodSeconds` to at least 45 (30s drainer + 15s buffer for Oban drain).

---

## Monitoring

### Prometheus Metrics

Scraped at **`GET /metrics`** (unauthenticated). Exposed via `telemetry_metrics_prometheus_core`.

Includes:
- Phoenix HTTP request metrics (duration, count, status)
- Ecto query metrics (duration, queue time)
- BEAM VM metrics (memory, process count, schedulers)
- Custom telemetry events from the orchestrator

### OpenTelemetry Traces

The application auto-instruments:
- **Phoenix** requests (`OpentelemetryPhoenix`)
- **Ecto** queries (`OpentelemetryEcto`)
- **Bandit** HTTP server (`OpentelemetryBandit`)

Traces are exported via OTLP HTTP (protobuf) to `OTEL_EXPORTER_OTLP_ENDPOINT` (default `http://localhost:4318`).

Service name: `infra-orchestrator`, version: `0.1.0`.

### Alert Webhooks

When `ALERTING_ENABLED=true`, the `AlertManager` GenServer subscribes to the PubSub alert feed and dispatches outbound webhook notifications.

**Inbound (from Alertmanager)**:
- `POST /api/v1/webhooks/alert` — unauthenticated endpoint that receives Alertmanager payloads
- Maps alertnames (`DailyCostCritical`, `ServiceDown`, etc.) to internal event types
- Broadcasts to PubSub for the AlertManager GenServer to evaluate

**Internal rules** (evaluated by AlertManager GenServer):
- `run_failed` (warning, 60s cooldown) — workflow run failure
- `run_exhausted` (warning, 60s cooldown) — all retries exhausted
- `budget_exceeded` (critical, 5m cooldown) — daily budget breached
- `budget_paused` (warning, 5m cooldown) — run paused for budget
- `circuit_breaker_open` (warning, 5m cooldown) — provider circuit opened

**Outbound formats**: `generic` (flat JSON), `slack` (attachments with color), `discord` (embeds), `pagerduty` (Events API v2), `teams` (MessageCard). Controlled by `ALERT_WEBHOOK_FORMAT`.

**Cooldown**: Duplicate alerts of the same rule are suppressed for `ALERT_COOLDOWN_MS` (default 5 minutes). Different rule types are independent.

**Testing**: `AlertManager.test_webhook/1` sends a test notification to the configured webhook URL.

### Phoenix LiveDashboard

Available at `/dashboard` in development (dev environment only). Provides real-time BEAM metrics, Ecto stats, and process inspection.

---

## Oban Job Queue

### Configuration

| Queue     | Concurrency | Purpose                              |
|-----------|-------------|--------------------------------------|
| `default` | 10          | General background jobs              |
| `patrol`  | 1           | Sequential patrol/scanning tasks     |

### Plugins

- **Lifeline**: Rescues stuck jobs after 30 minutes (`rescue_after: :timer.minutes(30)`).
- **Cron**: Scheduled periodic jobs (see below).

### Cron Schedule

| Schedule    | Worker                               | Description                    |
|-------------|--------------------------------------|--------------------------------|
| `0 * * * *` | `InfraOrchestrator.SessionCleaner`  | Hourly session cleanup         |

### Oban in Production

Oban uses the PostgreSQL `oban_jobs` table. No additional infrastructure is required.

During shutdown, `Application.prep_stop/1` drains both queues with `with_safety: true`, allowing in-progress jobs to complete before the node exits.

---

## Application Startup Sequence

The supervision tree starts in this order (single-node mode):

1. **RateLimitPersistence** -- Seeds the `:rate_limit` ETS table from DETS snapshot
2. **Telemetry** -- Telemetry poller and metrics
3. **Repo** -- PostgreSQL connection pool (Ecto)
4. **DNSCluster** -- Legacy DNS-based clustering (non-libcluster)
5. **PubSub** -- Phoenix PubSub for LiveView real-time updates
6. **RunRegistry** -- Local process registry for run lookup by ID
7. **Tenant.Registry** + **Tenant.Supervisor** -- Per-tenant isolation
8. **TaskSupervisor** -- Task.Supervisor for agent run spawning
9. **RunSupervisor** -- DynamicSupervisor for per-run GenServers
10. **WorkflowStore** -- YAML workflow file cache (polls for changes)
11. **BudgetTracker** -- ETS-backed cost accumulator
12. **ResultWriter** -- Serialized run manifest I/O
13. **CostEventReader** -- Tails `cost-events.jsonl` for session activity
14. **ExternalCircuitBreaker** -- Circuit breakers for external HTTP services
15. **LogBuffer** -- In-memory ring buffer for server logs
16. **AuditLogger** -- Auth/security event audit trail (`audit.jsonl`)
17. **Orchestrator** -- Core poll/dispatch/reconcile loop
18. **AlertManager** -- PubSub subscriber, rule evaluator, cooldown dedup, outbound webhook dispatcher
19. **SelfImprovement** -- Periodic KPI and prompt hint generation
20. **Oban** -- Job queue (PostgreSQL-backed)
21. **Endpoint** -- Phoenix HTTP server + LiveView WebSocket

In distributed mode, these are prepended before the list above:

1. **Cluster.Topology** -- libcluster node discovery
2. **Cluster.DistributedRegistry** -- Horde process registry
3. **DistributedSupervisor** -- Horde DynamicSupervisor
4. **DistributedStore** -- Mnesia-backed distributed state

Before the supervision tree starts, `Application.start/2` runs:
- `OpentelemetryPhoenix.setup()`, `OpentelemetryEcto.setup()`, `OpentelemetryBandit.setup()` (OTel auto-instrumentation)
- `InfraOrchestrator.ConfigValidator.validate!()` (fails fast on missing required config in prod)
- `:ets.new(:rate_limit, ...)` (creates the rate limiter ETS table)
- `:logger.add_handler(:log_buffer, ...)` (adds LogBuffer backend to Logger)

---

## Troubleshooting

### Application fails to start with missing env var error

The `ConfigValidator` requires `DATABASE_URL` and `SECRET_KEY_BASE` in production. Additionally:
- `CLUSTER_DNS_QUERY` is required when `CLUSTER_STRATEGY=dns`
- `CLUSTER_K8S_SERVICE` is required when `CLUSTER_STRATEGY=k8s`

Check the error message and set the missing variable.

### Database connection refused

Verify `DATABASE_URL` is correct and the PostgreSQL server is reachable. If using IPv6, set `ECTO_IPV6=true`. Check `POOL_SIZE` is not exceeding PostgreSQL's `max_connections`.

### Health check returns 503

Check which sub-check is failing in the response body:
- `repo: error` -- Database connection issue. Check PostgreSQL connectivity and pool exhaustion.
- `orchestrator: error` -- The Orchestrator GenServer has crashed. Check application logs.
- `budget_ets: error` -- The `:budget_tracker_events` ETS table is missing. The BudgetTracker process may have crashed.
- `workflows: error` -- No workflows loaded from the `workflows_dir`. Verify the directory path and file permissions.
- `oban: error` -- Oban process not running. Check database connectivity (Oban uses PostgreSQL).

### Nodes not forming a cluster

- **Gossip**: Ensure all nodes share the same `CLUSTER_GOSSIP_SECRET` and can reach each other on `CLUSTER_GOSSIP_PORT` (UDP).
- **DNS**: Verify the DNS query (`CLUSTER_DNS_QUERY`) resolves to the correct node IPs. Check `CLUSTER_DNS_POLL_INTERVAL`.
- **K8s**: Verify the service account has permissions to list pods. Check `CLUSTER_K8S_NAMESPACE` and `CLUSTER_K8S_SERVICE`.
- Ensure `RELEASE_NODE` is set correctly and the Erlang distribution port (4369/epmd or custom) is open between nodes.

### Mnesia table not available

If Mnesia tables time out during startup (15s default wait), check:
- `MNESIA_DIR` is writable and on persistent storage.
- The Mnesia directory is not corrupted. Try clearing it and letting tables recreate (data will be lost -- see `mnesia-backup.md` for recovery from PostgreSQL).
- In a cluster, ensure the node name (`RELEASE_NODE`) has not changed, as Mnesia schemas are node-name-dependent.

### Oban jobs stuck

The Lifeline plugin rescues stuck jobs after 30 minutes. To manually check:
```sql
SELECT id, queue, state, attempted_at FROM oban_jobs WHERE state = 'executing' ORDER BY attempted_at;
```

### High memory usage

- Check LogBuffer ring buffer size.
- Check ETS table sizes: `:ets.info(:rate_limit)`, `:ets.info(:budget_tracker_events)`.
- In production, use the LiveDashboard (dev only) or connect a remote shell:
  ```bash
  bin/infra_orchestrator remote
  ```

### Generating a SECRET_KEY_BASE

```bash
mix phx.gen.secret
```

Or in a release (without Mix):
```bash
openssl rand -base64 64
```
