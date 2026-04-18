# Failure Runbook

Operational procedures for diagnosing and recovering from common failure modes.
For deployment procedures, see [deployment-runbook.md](./deployment-runbook.md).
For Mnesia operations, see [mnesia-backup.md](./mnesia-backup.md).

---

## 1. DB Connection Exhaustion

**Symptoms**: `DBConnection.ConnectionError: checkout timeout` in logs, LiveViews returning empty data, health endpoint `/api/health/ready` returns 503 with `pool_utilization > 0.8`.

**Diagnose**:
```bash
# Check active connections
psql $DATABASE_URL -c "SELECT count(*), state FROM pg_stat_activity WHERE datname = current_database() GROUP BY state;"

# Check pool utilization via API
curl -s localhost:4801/api/health/ready | jq '.checks[] | select(.name == "repo")'

# Check for long-running queries
psql $DATABASE_URL -c "SELECT pid, now() - pg_stat_activity.query_start AS duration, query FROM pg_stat_activity WHERE state = 'active' AND now() - pg_stat_activity.query_start > interval '10 seconds' ORDER BY duration DESC;"
```

**Fix**:
1. Kill idle-in-transaction connections: `SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE state = 'idle in transaction' AND now() - state_change > interval '5 minutes';`
2. If persistent: increase pool size via `POOL_SIZE` env var (default 10, try 20)
3. If caused by a specific query: add `timeout: 5_000` option to the Ecto query

---

## 2. GenServer Mailbox Overflow

**Symptoms**: Growing memory for a specific process, slow responses from a LiveView or API endpoint, `Process.info(pid, :message_queue_len)` returns > 1000.

**Diagnose**:
```elixir
# Connect to the running node
bin/infra_orchestrator remote

# Find bloated processes
:recon.proc_count(:message_queue_len, 10)

# Inspect a specific GenServer
pid = GenServer.whereis(InfraOrchestrator.CostEventReader)
Process.info(pid, [:message_queue_len, :memory, :current_function])
```

**Fix**:
1. If the GenServer is recoverable: `GenServer.stop(pid, :normal)` — the supervisor will restart it
2. If the supervisor itself is stuck: identify which child via `:supervisor.which_children(InfraOrchestrator.Supervisor)`
3. Prevent recurrence: tune the tick interval (e.g., `@tick_interval` in CostEventReader), add backpressure via `Process.info(self(), :message_queue_len)` check

---

## 3. Circuit Breaker Stuck Open

**Symptoms**: All LLM calls failing with `{:blocked, cooldown_ms}`, or Docker sandbox calls returning blocked. Router LiveView shows circuit as "open".

**Diagnose**:
```elixir
bin/infra_orchestrator remote

# Check all circuit states
InfraOrchestrator.ExternalCircuitBreaker.status()
# => %{model_router: {:open, remaining_ms}, docker_daemon: {:closed, 0}}
```

**Fix**:
```elixir
# Reset a specific circuit
InfraOrchestrator.ExternalCircuitBreaker.reset(:model_router)

# Or via API
curl -X POST localhost:4801/api/v1/router/circuits/model_router/reset
```

If the upstream service is actually down, the circuit will re-open on the next failure. Fix the upstream first.

---

## 4. Mnesia Split-Brain

**Symptoms**: Inconsistent distributed state across cluster nodes, `DistributedStore` returning different values on different nodes.

**Diagnose**:
```elixir
bin/infra_orchestrator remote

:mnesia.system_info(:running_db_nodes)
:mnesia.system_info(:db_nodes)
# If these differ, you have a partition
```

**Fix**: See [mnesia-backup.md](./mnesia-backup.md) disaster recovery section. Quick steps:
1. Pick the authoritative node (most recent data)
2. On other nodes: `:mnesia.stop()`, delete Mnesia dir, `:mnesia.start()`
3. Let Mnesia replicate from the authoritative node

---

## 5. Oban Job Queue Stalled

**Symptoms**: Jobs stuck in `executing` state, no new jobs being picked up, backup job not running at 3:03 AM.

**Diagnose**:
```elixir
bin/infra_orchestrator remote

# Check queue status
Oban.check_queue(queue: :default)
Oban.check_queue(queue: :patrol)

# Find stuck jobs
import Ecto.Query
InfraOrchestrator.Repo.all(
  from j in Oban.Job,
  where: j.state == "executing" and j.attempted_at < ago(30, "minute"),
  select: %{id: j.id, worker: j.worker, attempted_at: j.attempted_at}
)
```

**Fix**:
```elixir
# Cancel stuck jobs
Oban.cancel_all_jobs(Oban.Job |> where(state: "executing") |> where([j], j.attempted_at < ago(30, "minute")))

# If Oban itself is stuck, restart it
Oban.pause_queue(queue: :default)
Oban.resume_queue(queue: :default)
```

The Lifeline plugin auto-rescues jobs stuck > 30 minutes, but check if it's running.

---

## 6. Budget Kill-Switch Activated

**Symptoms**: No new workflow runs starting, existing runs terminated, logs show "budget kill-switch activated".

**Diagnose**:
```elixir
bin/infra_orchestrator remote

InfraOrchestrator.Orchestrator.snapshot()
# Look for: %{halted: true, ...}

InfraOrchestrator.BudgetTracker.daily_status()
# => %{spent: 95.0, remaining: 5.0, exceeded?: true}
```

**Fix**:
```elixir
# Resume dispatching (does NOT reset the budget)
InfraOrchestrator.Orchestrator.resume_dispatch()

# If budget is legitimately exceeded, increase the daily limit
Application.put_env(:infra_orchestrator, :orchestrator,
  Keyword.put(
    Application.get_env(:infra_orchestrator, :orchestrator, []),
    :daily_budget_usd,
    200.0
  )
)
```

For a permanent increase, set `DAILY_BUDGET_LIMIT_USD` env var and restart.

---

## 7. Backup Job Failure

**Symptoms**: No recent files in backup directory, Oban job in `retryable`/`discarded` state.

**Diagnose**:
```bash
# Check backup directory
ls -la ${BACKUP_DIR:-/tmp/infra-orchestrator-backups}/pg/
ls -la ${BACKUP_DIR:-/tmp/infra-orchestrator-backups}/vault/

# Check Oban job logs
```
```elixir
bin/infra_orchestrator remote

import Ecto.Query
InfraOrchestrator.Repo.all(
  from j in Oban.Job,
  where: j.worker == "InfraOrchestrator.Jobs.BackupJob",
  order_by: [desc: j.attempted_at],
  limit: 5,
  select: %{id: j.id, state: j.state, errors: j.errors, attempted_at: j.attempted_at}
)
```

**Fix**:
1. If `pg_dump` not found: install PostgreSQL client tools or set `PG_DUMP_PATH` env var
2. If `rsync` failed: check `VAULT_PATH` points to a valid directory
3. If Mnesia backup failed: Mnesia may not be running (single-node mode) — this is normal
4. Manual run: `bin/infra_orchestrator eval 'InfraOrchestrator.Jobs.BackupJob.perform(%Oban.Job{})'`

---

## 8. OTel Exporter Down

**Symptoms**: No spans appearing in Grafana/Jaeger, no metrics in Prometheus, but the app itself is healthy.

**Diagnose**:
```bash
# Check if the OTLP endpoint is reachable
curl -s ${OTEL_EXPORTER_OTLP_ENDPOINT:-http://localhost:4318}/v1/traces -X POST -d '{}' -H 'Content-Type: application/json'

# Check for exporter errors in logs
grep -i "otel\|opentelemetry\|exporter" /path/to/logs | tail -20
```

**Fix**:
1. Verify `OTEL_EXPORTER_OTLP_ENDPOINT` env var is correct (default: `http://localhost:4318`)
2. Restart the OTel collector: `docker restart otel-collector` or `systemctl restart otel-collector`
3. If the collector is down and can't restart, the app continues functioning — telemetry data is lost but no user impact
4. To disable OTel temporarily: set `OTEL_SDK_DISABLED=true` and restart the app
