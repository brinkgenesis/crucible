# Mnesia Operations Guide

Operational procedures for the Mnesia distributed state layer in the Infra Orchestrator.

---

## Overview

Mnesia is used as a **distributed in-memory/disc cache** for workflow run and phase state that needs to be shared across cluster nodes with low latency. It is **not** the source of truth -- PostgreSQL (via Ecto) is the canonical store. Mnesia provides:

- Fast local reads without database round-trips
- Automatic replication across cluster nodes
- Transactional writes with last-write-wins conflict resolution (via `updated_at` timestamps)
- Persistent disc_copies that survive node restarts

If Mnesia data is lost entirely, the orchestrator continues to function using PostgreSQL. Mnesia can be rebuilt from the database.

---

## Configuration

### Environment Variable

| Variable    | Default                              | Description                          |
|-------------|--------------------------------------|--------------------------------------|
| `MNESIA_DIR`| `/data/mnesia/${RELEASE_NAME}`       | Directory for Mnesia data files      |

Set in `rel/env.sh.eex`:

```bash
export MNESIA_DIR="${MNESIA_DIR:-/data/mnesia/${RELEASE_NAME}}"
```

The Dockerfile defaults to `/data/mnesia/infra_orchestrator` and creates the directory with ownership set to the `app` user.

### Requirements

- The `MNESIA_DIR` path must be on **persistent storage** (a Docker volume, PVC, or host mount). Ephemeral container filesystems will lose Mnesia data on restart.
- The directory must be **writable** by the application user.
- The Mnesia schema is **node-name-dependent**. If `RELEASE_NODE` changes, Mnesia will not recognize its existing data. Either keep node names stable or clear the directory.

---

## Tables

All tables are created by `InfraOrchestrator.State.Schema.create_tables/0` during `DistributedStore` GenServer init. Table creation is idempotent -- existing tables are skipped.

### distributed_runs

Workflow run manifests.

| Attribute       | Description                               |
|-----------------|-------------------------------------------|
| `id`            | Run ID (primary key)                      |
| `workflow_type` | Type of workflow being executed            |
| `status`        | Run status (`:pending`, `:running`, etc.) |
| `phases`        | List of phase definitions                 |
| `workspace_path`| Path to the workspace directory           |
| `branch`        | Git branch for the run                    |
| `plan_note`     | Vault note reference for the plan         |
| `plan_summary`  | Short summary of the plan                 |
| `budget_usd`    | Budget allocated for this run             |
| `client_id`     | Client/tenant identifier                  |
| `started_at`    | UTC timestamp when run started            |
| `completed_at`  | UTC timestamp when run completed          |
| `error`         | Error details (if failed)                 |
| `data`          | Arbitrary metadata map                    |
| `updated_at`    | Last modification timestamp (conflict resolution) |
| `version`       | Monotonic version counter                 |

### distributed_phases

Phase records within workflow runs.

| Attribute     | Description                                |
|---------------|--------------------------------------------|
| `id`          | Phase ID (primary key)                     |
| `run_id`      | Parent run ID                              |
| `name`        | Phase name                                 |
| `type`        | Phase execution type                       |
| `status`      | Phase status                               |
| `prompt`      | Prompt template for the phase              |
| `phase_index` | Ordering index within the run              |
| `data`        | Arbitrary metadata map                     |
| `updated_at`  | Last modification timestamp                |
| `version`     | Monotonic version counter                  |

### distributed_results

Phase execution results.

| Attribute   | Description                                  |
|-------------|----------------------------------------------|
| `id`        | Result ID (primary key)                      |
| `run_id`    | Parent run ID                                |
| `phase_id`  | Parent phase ID                              |
| `exit_code` | Process exit code                            |
| `output`    | Captured output/response                     |
| `data`      | Arbitrary metadata map                       |
| `updated_at`| Last modification timestamp                  |
| `version`   | Monotonic version counter                    |

### distributed_circuit_breakers

Per-workflow circuit breaker state.

| Attribute              | Description                             |
|------------------------|-----------------------------------------|
| `workflow_name`        | Workflow identifier (primary key)       |
| `state`                | Circuit state (`:closed`, `:open`, etc.)|
| `consecutive_failures` | Number of consecutive failures          |
| `opened_at`            | When the circuit was opened             |
| `cooldown_ms`          | Cooldown period before half-open        |
| `last_failed_at`       | Timestamp of last failure               |
| `updated_at`           | Last modification timestamp             |
| `version`              | Monotonic version counter               |

### Storage Type

All tables use **`disc_copies`** with **`:set`** type (key-value, one record per key). This means data is held in both RAM and on disc -- reads are memory-speed, writes are persisted to disc for durability.

---

## Backup Procedure

### Interactive (Remote Shell)

Connect to a running node:

```bash
bin/infra_orchestrator remote
```

Create a backup:

```erlang
:mnesia.backup('/data/mnesia/backup/backup_2026-03-10.bak')
```

This creates a binary backup of all Mnesia tables. The backup file contains the schema and all table data.

### Scripted Backup

```bash
bin/infra_orchestrator eval '
  backup_path = "/data/mnesia/backup/backup_#{Date.utc_today()}.bak"
  File.mkdir_p!(Path.dirname(backup_path))
  case :mnesia.backup(String.to_charlist(backup_path)) do
    :ok -> IO.puts("Backup created: #{backup_path}")
    {:error, reason} -> IO.puts("Backup failed: #{inspect(reason)}")
  end
'
```

### Backup Best Practices

- Schedule backups via cron or a Kubernetes CronJob.
- Store backups on a separate volume or object storage (S3, GCS).
- Mnesia backups are node-name-dependent. Label backups with the node name.
- Backups are point-in-time snapshots. There is no WAL/incremental backup in Mnesia.

---

## Restore Procedure

### Full Restore

Connect to a running node (or use `eval`):

```erlang
:mnesia.restore('/data/mnesia/backup/backup_2026-03-10.bak', [{:default_op, :recreate_tables}])
```

The `:recreate_tables` option drops and recreates tables from the backup. Use `:clear_tables` to clear existing data before restoring without dropping the table definition.

### Selective Restore (Single Table)

```erlang
:mnesia.restore('/data/mnesia/backup/backup_2026-03-10.bak', [
  {:default_op, :skip_tables},
  {:recreate_tables, [:distributed_runs]}
])
```

This restores only the `distributed_runs` table and skips all others.

### Restore Options

| Option             | Description                                              |
|--------------------|----------------------------------------------------------|
| `recreate_tables`  | Drop and recreate tables from backup                     |
| `clear_tables`     | Clear existing data, then load from backup               |
| `keep_tables`      | Merge backup data with existing data (may cause conflicts)|
| `skip_tables`      | Skip listed tables during restore                        |

---

## Cluster Node Management

### How Replication Works

When a new node joins the cluster (detected via `{:mnesia_system_event, {:mnesia_up, node}}`), the `DistributedStore` GenServer automatically:

1. Calls `Schema.ensure_schema(node)` to add a `disc_copies` schema replica on the new node.
2. Adds `disc_copies` replicas of all four tables on the new node via `:mnesia.add_table_copy/3`.

This is fully automatic -- no manual intervention is needed for normal cluster scaling.

### Adding a Node Manually

If automatic replication did not trigger (e.g., the node joined before DistributedStore started):

```erlang
# On any existing node's remote shell:
node = :"infra_orchestrator@new-host.example.com"
InfraOrchestrator.State.Schema.ensure_schema(node)
```

### Removing a Node

When a node leaves the cluster permanently:

```erlang
node = :"infra_orchestrator@old-host.example.com"

# Remove table copies from the departing node
for table <- InfraOrchestrator.State.Schema.tables() do
  :mnesia.del_table_copy(table, node)
end

# Remove schema copy
:mnesia.del_table_copy(:schema, node)
```

### Checking Cluster Status

```erlang
# List all known Mnesia nodes
:mnesia.system_info(:db_nodes)

# List currently running Mnesia nodes
:mnesia.system_info(:running_db_nodes)

# Check table replication status
:mnesia.table_info(:distributed_runs, :disc_copies)
```

---

## Disaster Recovery

### Scenario 1: Mnesia Directory Corrupted / Lost (Single Node)

If the Mnesia directory is lost on a single node in a multi-node cluster:

1. Stop the affected node.
2. Clear the Mnesia directory: `rm -rf $MNESIA_DIR/*`
3. Restart the node. On startup, `DistributedStore.init/1` will:
   - Call `:mnesia.create_schema([node()])` to create a fresh schema.
   - Call `Schema.create_tables()` to create empty tables.
4. When the node rejoins the cluster, the `:mnesia_up` event triggers `Schema.ensure_schema/1`, which replicates data from the other nodes.

### Scenario 2: All Mnesia Data Lost (Full Cluster)

PostgreSQL is the source of truth. To rebuild Mnesia from the database:

1. Clear Mnesia directories on all nodes: `rm -rf $MNESIA_DIR/*`
2. Restart one node. It will create empty Mnesia tables.
3. Backfill from PostgreSQL. In a remote shell or eval:

```elixir
# Re-populate distributed_runs from PostgreSQL
alias InfraOrchestrator.{Repo, State.DistributedStore}

# Assuming a Runs schema module exists:
Repo.all(InfraOrchestrator.Runs.Run)
|> Enum.each(fn run ->
  attrs = Map.from_struct(run) |> Map.delete(:__meta__)
  DistributedStore.put_run(run.id, attrs)
end)

# Repeat for phases, results, and circuit breakers as needed.
```

4. Start remaining nodes. They will replicate from the first node automatically.

### Scenario 3: Node Name Changed

Mnesia schemas are bound to the Erlang node name (`RELEASE_NODE`). If the node name changes:

1. The old Mnesia directory is unusable.
2. Clear the directory: `rm -rf $MNESIA_DIR/*`
3. Restart. The node creates a fresh schema with the new name.
4. In a cluster, data replicates from other nodes. In a single-node setup, backfill from PostgreSQL (see Scenario 2).

**Prevention**: Keep `RELEASE_NODE` stable. In Kubernetes, use a StatefulSet with stable network identities, or set `RELEASE_NODE` explicitly via environment variable.

### Scenario 4: Split-Brain Recovery

If network partitions cause a split-brain:

1. Identify which partition has the most recent data (check `updated_at` timestamps).
2. Stop nodes in the stale partition.
3. Clear their Mnesia directories.
4. Restart them so they rejoin the authoritative partition and replicate fresh data.

Mnesia uses last-write-wins conflict resolution via `updated_at` timestamps, so brief partitions typically resolve automatically when connectivity is restored. Persistent partitions require manual intervention.

---

## Monitoring Mnesia

### Key Metrics to Watch

```erlang
# Table sizes (record count)
:mnesia.table_info(:distributed_runs, :size)
:mnesia.table_info(:distributed_phases, :size)
:mnesia.table_info(:distributed_results, :size)
:mnesia.table_info(:distributed_circuit_breakers, :size)

# Memory usage (words)
:mnesia.table_info(:distributed_runs, :memory)

# Transaction statistics
:mnesia.system_info(:transaction_commits)
:mnesia.system_info(:transaction_failures)

# Held locks (should be 0 when idle)
:mnesia.system_info(:held_locks)
```

### Log Messages

The `DistributedStore` logs at these levels:

| Level     | Message Pattern                            | Meaning                          |
|-----------|--------------------------------------------|----------------------------------|
| `info`    | `DistributedStore: initialized on <node>`  | Startup complete                 |
| `info`    | `DistributedStore: node joined`            | New node discovered, replicating |
| `info`    | `DistributedStore: node left`              | Node departed cluster            |
| `info`    | `Mnesia: created table <name>`             | Table created for first time     |
| `info`    | `Mnesia: replicated <table> to <node>`     | Table copy added to new node     |
| `warning` | `DistributedStore: wait_for_tables`        | Tables slow to become available  |
| `error`   | `DistributedStore: table creation failed`  | Schema.create_tables error       |
| `error`   | `Mnesia: failed to create/replicate`       | Individual table operation failed|
