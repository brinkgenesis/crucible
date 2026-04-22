defmodule Crucible.Orchestrator do
  @moduledoc """
  Core GenServer: poll for pending runs, dispatch to per-run GenServers, reconcile.

  ## Execution Path: GenServer Poll/Dispatch (In-Memory)

  This module runs a periodic tick loop that:
  1. **Scans** — reads `.claude-flow/runs/*.json` for pending/budget_paused manifests
  2. **Dispatches** — creates a `Run` via `WorkflowRunner`, starts a `RunServer`
     via `RunSupervisor` (DynamicSupervisor)

  Each run gets its own GenServer (`RunServer`) that handles execution, retries,
  and lifecycle. The Orchestrator tracks only workflow-level concerns: circuit
  breakers, concurrency limits, and the completed-run set.

  Uses in-memory circuit breakers (`Orchestrator.CircuitBreaker`).
  Run processes register in `RunRegistry` for O(1) lookup.

  ## Distributed Dispatch

  In a multi-node cluster (via libcluster), uses `:pg` process groups for
  cross-node run registry. Dispatch decisions incorporate **node affinity**
  (prefer the node where the run's working directory is locally mounted)
  and **work stealing** (idle nodes pull pending runs from busy nodes).

  ## Alternative Path: Oban/WorkflowJob (DB-Backed)

  See `Crucible.Jobs.WorkflowJob` for the Oban-backed execution path.
  Both paths converge at `PhaseRunner.execute/3` for actual phase execution.
  """
  use GenServer

  require Logger

  alias Crucible.Orchestrator.{State, RunSupervisor}
  alias Crucible.{BudgetTracker, Events, Status, Workspace, WorkflowRunner}
  alias Crucible.State.DistributedStore
  alias Crucible.Telemetry.Spans
  alias Crucible.Tenant.Supervisor, as: TenantSupervisor

  @pg_scope :crucible_runs
  @pg_group :active_orchestrators
  @work_steal_interval_ms 10_000
  @idle_threshold 0
  @completed_ttl_ms :timer.hours(24)
  @prune_interval_ms :timer.minutes(30)
  @call_timeout 10_000

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns a snapshot of the orchestrator state for dashboard rendering."
  @spec snapshot() :: map()
  def snapshot do
    GenServer.call(__MODULE__, :snapshot, @call_timeout)
  end

  @doc "Reset all workflow circuit breakers to closed state."
  @spec reset_circuit_breakers() :: :ok
  def reset_circuit_breakers do
    send(__MODULE__, :reset_circuit_breakers)
    :ok
  end

  @doc "Reset circuit breaker for a specific workflow type."
  @spec reset_circuit_breaker(String.t()) :: :ok
  def reset_circuit_breaker(workflow) do
    send(__MODULE__, {:reset_circuit_breaker, workflow})
    :ok
  end

  @doc "Submits a run manifest for execution."
  @spec submit_run(map()) :: :ok | {:error, term()}
  def submit_run(run_manifest) do
    GenServer.call(__MODULE__, {:submit_run, run_manifest}, @call_timeout)
  end

  @doc "Lists all known runs with their current status."
  @spec list_runs() :: [map()]
  def list_runs do
    GenServer.call(__MODULE__, :list_runs, @call_timeout)
  end

  @doc "Returns cached run stats from disk manifests (refreshed every 30s)."
  @spec run_stats() :: map()
  def run_stats do
    GenServer.call(__MODULE__, :run_stats, @call_timeout)
  end

  @doc "Returns up to `limit` recent runs from disk manifests, sorted by updatedAt desc."
  @spec recent_runs(non_neg_integer()) :: [map()]
  def recent_runs(limit \\ 10) do
    GenServer.call(__MODULE__, {:recent_runs, limit}, @call_timeout)
  end

  @doc "Cancels a running workflow."
  @spec cancel_run(String.t()) :: :ok | {:error, :not_found}
  def cancel_run(run_id) do
    case lookup_run(run_id) do
      {:ok, pid, _meta} ->
        Crucible.Orchestrator.RunServer.cancel(pid)

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc """
  Look up a running task by run_id. Checks local Registry first, then
  queries peer orchestrator nodes via :pg for cross-node discovery.
  """
  @spec lookup_run(String.t()) :: {:ok, pid(), map()} | :not_found
  def lookup_run(run_id) do
    case Registry.lookup(Crucible.RunRegistry, run_id) do
      [{pid, meta}] ->
        {:ok, pid, meta}

      [] ->
        lookup_run_distributed(run_id)
    end
  end

  defp lookup_run_distributed(run_id) do
    peers = peer_orchestrators()

    Enum.find_value(peers, :not_found, fn peer_pid ->
      try do
        case GenServer.call(peer_pid, {:remote_lookup, run_id}, 5_000) do
          {:ok, pid, meta} -> {:ok, pid, meta}
          :not_found -> nil
        end
      catch
        :exit, _ -> nil
      end
    end)
  end

  @doc """
  Emergency budget kill-switch: terminates all running agents and halts new
  dispatches until the flag is cleared. Returns the count of terminated runs.
  """
  @spec budget_kill_switch() :: {:ok, non_neg_integer()}
  def budget_kill_switch do
    GenServer.call(__MODULE__, :budget_kill_switch, @call_timeout)
  end

  @doc "Resumes dispatching after a kill-switch halt."
  @spec resume_dispatch() :: :ok
  def resume_dispatch do
    GenServer.call(__MODULE__, :resume_dispatch, @call_timeout)
  end

  @doc "Extract tenant_id from a run manifest (supports snake_case and camelCase keys)."
  @spec extract_tenant_id(map()) :: String.t()
  def extract_tenant_id(manifest) do
    manifest["tenant_id"] || manifest["tenantId"] || "default"
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    config = Keyword.get(opts, :config, Crucible.Config.load!())
    state = State.new(config)

    # Join :pg group so other nodes can discover this orchestrator
    ensure_pg_started()
    :pg.join(@pg_scope, @pg_group, self())

    if orchestrator_disabled?() do
      Logger.info("Orchestrator: polling disabled (config :disabled=true) — idle mode")
      {:ok, state}
    else
      schedule_tick(state.poll_interval_ms)
      schedule_work_steal()
      schedule_prune()

      # Startup cleanup (runs in background, non-blocking)
      spawn(fn ->
        purge_stale_artifacts(state.runs_dir)
        kill_orphaned_tmux_sessions()
        Workspace.prune_stale_worktrees()
      end)

      Logger.info(
        "Orchestrator started on #{node()} (poll_interval=#{state.poll_interval_ms}ms, runs_dir=#{state.runs_dir})"
      )

      {:ok, state}
    end
  end

  defp orchestrator_disabled? do
    :crucible
    |> Application.get_env(:orchestrator, [])
    |> Keyword.get(:disabled, false)
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    active = RunSupervisor.active_count()

    snapshot = %{
      running: active,
      completed: map_size(state.completed),
      runs: list_running_runs_map(),
      circuit_breakers:
        Map.new(state.circuit_breakers, fn {wf, cb} ->
          {wf, %{state: cb.state, failures: cb.consecutive_failures}}
        end),
      poll_interval_ms: state.poll_interval_ms,
      budget_halted: state.budget_halted
    }

    {:reply, snapshot, state}
  end

  def handle_call(:list_runs, _from, state) do
    running_runs =
      Registry.select(Crucible.RunRegistry, [
        {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
      ])
      |> Enum.map(fn {run_id, _pid, meta} ->
        meta = meta || %{}

        %Crucible.Types.Run{
          id: run_id,
          workflow_type: Map.get(meta, :workflow_type, "unknown"),
          status: :running,
          phases: []
        }
      end)

    {:reply, running_runs, state}
  end

  def handle_call(:run_stats, _from, state) do
    {stats, state} = ensure_run_stats_cache(state)
    {:reply, stats, state}
  end

  def handle_call({:recent_runs, limit}, _from, state) do
    {_stats, state} = ensure_run_stats_cache(state)
    recent = state |> Map.get(:run_stats_recent, []) |> Enum.take(limit)
    {:reply, recent, state}
  end

  def handle_call({:submit_run, run_manifest}, _from, state) do
    Spans.with_span(
      "orchestrator.submit_run",
      %{"run.workflow" => run_manifest["name"] || ""},
      fn ->
        alias Crucible.Validation.Manifest

        case Manifest.validate(run_manifest) do
          {:ok, validated} ->
            # Resolve workflow config + card metadata before persisting,
            # so the manifest on disk always has phases and plan context
            resolved = resolve_workflow_config(validated)

            # Verify that resolution produced phases — otherwise the run will
            # sit as "pending" forever with no way for the client to discover why
            case resolved do
              %{"phases" => [_ | _]} ->
                case write_run_manifest(state.runs_dir, resolved) do
                  :ok -> {:reply, :ok, state}
                  {:error, _} = err -> {:reply, err, state}
                end

              _ ->
                workflow_name =
                  resolved["workflow_name"] || resolved["workflowName"] || resolved["name"]

                Logger.warning(
                  "Orchestrator: submit_run rejected — no phases resolved for workflow #{inspect(workflow_name)}"
                )

                {:reply,
                 {:error,
                  {:workflow_resolution_failed,
                   "No phases found for workflow '#{workflow_name}'. Check that the workflow exists in WorkflowStore."}},
                 state}
            end

          {:error, errors} ->
            {:reply, {:error, {:validation_failed, errors}}, state}
        end
      end
    )
  end

  def handle_call(:budget_kill_switch, _from, state) do
    Spans.with_span("orchestrator.kill_switch", fn ->
      killed = RunSupervisor.terminate_all()

      Logger.warning(
        "Orchestrator: BUDGET KILL SWITCH activated — terminated #{killed} runs, dispatching halted"
      )

      {:reply, {:ok, killed}, %{state | budget_halted: true}}
    end)
  end

  def handle_call(:resume_dispatch, _from, state) do
    Logger.info("Orchestrator: dispatching resumed after kill-switch")
    {:reply, :ok, %{state | budget_halted: false}}
  end

  # Remote peer queries: look up a run in *this* node's local registry
  def handle_call({:remote_lookup, run_id}, _from, state) do
    result =
      case Registry.lookup(Crucible.RunRegistry, run_id) do
        [{pid, meta}] -> {:ok, pid, meta}
        [] -> :not_found
      end

    {:reply, result, state}
  end

  # Remote peer queries: return pending runs for work stealing
  def handle_call(:pending_runs, _from, state) do
    pending = scan_pending_runs(state)
    {:reply, pending, state}
  end

  # Remote peer queries: report active run count for load balancing
  def handle_call(:load_info, _from, state) do
    active = RunSupervisor.active_count()

    info = %{
      node: node(),
      active_runs: active,
      max_concurrent: state.max_concurrent_runs,
      available_slots: max(state.max_concurrent_runs - active, 0)
    }

    {:reply, info, state}
  end

  @impl true
  def handle_info(:tick, state) do
    Spans.with_span("orchestrator.tick", fn ->
      state = run_poll_cycle(state)
      schedule_tick(state.poll_interval_ms)
      {:noreply, state}
    end)
  end

  def handle_info({:run_lifecycle, run_id, :completed}, state) do
    state = %{
      state
      | completed: Map.put(state.completed, run_id, System.monotonic_time(:millisecond))
    }

    {:noreply, state}
  end

  def handle_info({:run_lifecycle, run_id, :budget_paused}, state) do
    Logger.info("Orchestrator: run #{run_id} paused (budget exceeded)")
    Events.broadcast_alert_event(:budget_paused, %{run_id: run_id})
    # Remove from completed so it can be re-dispatched
    state = %{state | completed: Map.delete(state.completed, run_id)}
    {:noreply, state}
  end

  def handle_info({:run_lifecycle, run_id, :exhausted}, state) do
    wf = run_workflow_type(run_id)
    Events.broadcast_alert_event(:run_exhausted, %{run_id: run_id, workflow_type: wf})

    state = %{
      state
      | completed: Map.put(state.completed, run_id, System.monotonic_time(:millisecond))
    }

    {:noreply, state}
  end

  def handle_info({:run_lifecycle, _run_id, {:failed_retrying, _attempt}}, state) do
    {:noreply, state}
  end

  def handle_info(:maybe_steal_work, state) do
    state = maybe_steal_work(state)
    schedule_work_steal()
    {:noreply, state}
  end

  def handle_info(:prune_completed, state) do
    state = prune_completed(state)
    schedule_prune()
    {:noreply, state}
  end

  def handle_info(:reset_circuit_breakers, state) do
    Logger.info("Orchestrator: all circuit breakers reset")
    {:noreply, %{state | circuit_breakers: %{}}}
  end

  def handle_info({:reset_circuit_breaker, workflow}, state) do
    Logger.info("Orchestrator: circuit breaker reset for #{workflow}")
    {:noreply, %{state | circuit_breakers: Map.delete(state.circuit_breakers, workflow)}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Poll/Dispatch ---

  defp schedule_tick(interval) do
    Process.send_after(self(), :tick, interval)
  end

  defp schedule_prune do
    Process.send_after(self(), :prune_completed, @prune_interval_ms)
  end

  # Evict completed run IDs and stale circuit breakers older than TTL to bound memory.
  defp prune_completed(state) do
    now = System.monotonic_time(:millisecond)

    # Normalize: guard against stale BEAM where completed was a MapSet instead of a plain map.
    # A MapSet struct passed to Map.filter yields {:map, %{}} entries → ArithmeticError.
    completed =
      case state.completed do
        m when is_map(m) and not is_struct(m) -> m
        _ -> %{}
      end

    pruned =
      Map.filter(completed, fn
        {_run_id, completed_at} when is_integer(completed_at) ->
          now - completed_at < @completed_ttl_ms

        _ ->
          false
      end)

    # Prune circuit breakers: remove closed breakers whose last failure was > 24h ago
    pruned_cbs =
      Map.filter(state.circuit_breakers, fn {_wf, cb} ->
        case cb do
          %{state: :closed, last_failed_at: nil} -> false
          %{state: :closed, last_failed_at: ts} -> now - ts < @completed_ttl_ms
          _ -> true
        end
      end)

    %{state | completed: pruned, circuit_breakers: pruned_cbs}
  end

  defp run_poll_cycle(state) do
    scan_and_dispatch(state)
  end

  defp scan_and_dispatch(%{budget_halted: true} = state), do: state

  defp scan_and_dispatch(state) do
    active = RunSupervisor.active_count()

    if active >= state.max_concurrent_runs do
      state
    else
      case BudgetTracker.daily_status() do
        %{exceeded?: true} ->
          state

        _budget ->
          available_slots = state.max_concurrent_runs - active
          pending_runs = scan_pending_runs(state)

          pending_runs
          |> Enum.take(available_slots)
          |> Enum.reduce(state, fn run_manifest, acc ->
            tenant_id = extract_tenant_id(run_manifest)

            case ensure_tenant_ready(tenant_id) do
              :ok ->
                dispatch_run(acc, run_manifest)

              {:error, reason} ->
                run_id = run_manifest["run_id"] || run_manifest["runId"]

                Logger.error(
                  "Orchestrator: skipping run #{run_id}, tenant #{tenant_id} init failed: #{inspect(reason)}"
                )

                acc
            end
          end)
      end
    end
  end

  # Lazily ensures the tenant's supervision subtree is running.
  # Returns :ok or {:error, reason}.
  defp ensure_tenant_ready(tenant_id) do
    case TenantSupervisor.ensure_tenant(tenant_id) do
      {:ok, _pid} -> :ok
      {:error, _} = err -> err
    end
  end

  defp scan_pending_runs(state) do
    case safe_store_call(fn -> DistributedStore.scan_pending_runs() end) do
      {:ok, runs} when is_list(runs) ->
        runs
        |> Enum.filter(fn manifest ->
          run_id = manifest[:id] || manifest["run_id"] || manifest["runId"]

          run_id &&
            not is_run_active?(run_id) &&
            not Map.has_key?(state.completed, run_id)
        end)
        |> Enum.sort_by(fn m -> m[:started_at] || m["created_at"] || "" end)

      _ ->
        # Fallback to file-based scanning if distributed store is unavailable
        scan_pending_runs_from_files(state)
    end
  end

  defp scan_pending_runs_from_files(state) do
    dir = state.runs_dir

    if File.dir?(dir) do
      dir
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.reject(fn path ->
        name = Path.basename(path)

        String.ends_with?(name, ".result.json") or
          String.ends_with?(name, ".lock") or
          String.ends_with?(name, ".tmp") or
          String.ends_with?(name, ".dod.json") or
          String.ends_with?(name, ".done") or
          String.contains?(name, "-snapshot")
      end)
      |> Enum.flat_map(fn path ->
        case read_run_manifest(path) do
          {:ok, manifest} ->
            run_id = extract_run_id(manifest)

            if run_id &&
                 not is_run_active?(run_id) &&
                 not Map.has_key?(state.completed, run_id) &&
                 manifest_dispatchable?(manifest) &&
                 not manifest_expired?(path) do
              [Map.put(manifest, "_source_path", path)]
            else
              []
            end

          {:error, _} ->
            []
        end
      end)
      |> Enum.sort_by(fn m -> m["created_at"] || "" end)
    else
      []
    end
  end

  defp manifest_dispatchable?(manifest) do
    status = manifest["status"] || "pending"
    status in ["pending", "running", "budget_paused"]
  end

  @manifest_max_age_hours 24

  defp manifest_expired?(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        age_hours = (System.system_time(:second) - mtime) / 3600
        age_hours > @manifest_max_age_hours

      _ ->
        false
    end
  end

  defp dispatch_run(state, manifest) do
    run_id = extract_run_id(manifest)
    tenant_id = extract_tenant_id(manifest)

    workflow_type =
      manifest["workflow_name"] || manifest["workflowName"] || manifest["name"] || "unknown"

    # Per-tenant budget check — one tenant's exhaustion must not block others
    case BudgetTracker.daily_status(tenant_id) do
      %{exceeded?: true} ->
        Logger.info("Orchestrator: skipping run #{run_id}, tenant #{tenant_id} budget exceeded")

        state

      _budget ->
        # Note: per-workflow circuit breaker removed (2026-04-05).
        # It caused cascade failures: one bad card in a workflow type would
        # block ALL cards of that type. Per-adapter CBs (ClaudeSdk, ClaudePort)
        # handle actual execution failures at the right granularity.

        # Node affinity: check if another node is better suited for this run
        preferred = preferred_node_for_run(manifest)

        if preferred != node() do
          Logger.info(
            "Orchestrator: run #{run_id} has affinity for #{preferred}, deferring dispatch"
          )

          state
        else
          Logger.info("Orchestrator: dispatching run #{run_id} (#{workflow_type}) on #{node()}")

          do_dispatch_run(state, manifest, run_id, tenant_id)
        end
    end
  end

  defp do_dispatch_run(state, manifest, run_id, tenant_id) do
    # Acquire a file lock to prevent concurrent dispatch of the same run
    # across nodes. If we can't claim it, another node won.
    lock_path = Path.join(state.runs_dir, "#{run_id}.lock")

    if acquire_dispatch_lock(lock_path) do
      do_dispatch_run_locked(state, manifest, run_id, tenant_id, lock_path)
    else
      Logger.debug("Orchestrator: run #{run_id} locked by another node, skipping")
      state
    end
  end

  defp do_dispatch_run_locked(state, manifest, run_id, tenant_id, lock_path) do
    # If manifest lacks phases, resolve from WorkflowStore and merge
    manifest = resolve_workflow_config(manifest)

    case WorkflowRunner.create_run(manifest) do
      {:ok, run} ->
        run_opts = [
          infra_home: Keyword.get(state.config, :repo_root, File.cwd!()),
          runs_dir: state.runs_dir,
          tenant_id: tenant_id
        ]

        max_retries = Keyword.get(state.config, :max_retries, 3)

        case RunSupervisor.start_run(
               run: run,
               run_opts: run_opts,
               max_retries: max_retries,
               orchestrator_pid: self(),
               tenant_id: tenant_id
             ) do
          {:ok, _pid} ->
            Logger.info(
              "Orchestrator: dispatched run #{run_id} (#{run.workflow_type}) tenant=#{tenant_id}"
            )

            update_manifest_status(state.runs_dir, run_id, "running", manifest["_source_path"])
            release_dispatch_lock(lock_path)
            state

          {:error, {:already_started, _pid}} ->
            Logger.info("Orchestrator: run #{run_id} already started, skipping duplicate")
            release_dispatch_lock(lock_path)
            state

          {:error, reason} ->
            Logger.error(
              "Orchestrator: failed to start RunServer for #{run_id}: #{inspect(reason)}"
            )

            release_dispatch_lock(lock_path)
            state
        end

      {:error, reason} ->
        Logger.error(
          "Orchestrator: failed to create run from manifest #{run_id}: #{inspect(reason)}"
        )

        # Mark manifest as "failed" to prevent infinite retry loop
        source_path = manifest["_source_path"]
        update_manifest_status(state.runs_dir, run_id, "failed", source_path)
        release_dispatch_lock(lock_path)
        state
    end
  end

  # If the manifest doesn't have phases (e.g. submitted via webhook), resolve
  # the workflow config from WorkflowStore and merge manifest overrides into it.
  defp resolve_workflow_config(%{"phases" => [_ | _]} = manifest), do: manifest

  defp resolve_workflow_config(manifest) do
    workflow_name = manifest["workflow_name"] || manifest["workflowName"] || manifest["name"]

    manifest =
      case workflow_name && Crucible.WorkflowStore.get(workflow_name) do
        {:ok, workflow_config} ->
          # Workflow config provides phases; manifest overrides (run_id, task_description, etc.)
          Map.merge(workflow_config, manifest)

        _ ->
          manifest
      end

    # Enrich from card metadata if card_id is present but plan_note is missing
    enrich_from_card(manifest)
  end

  defp enrich_from_card(%{"card_id" => card_id} = manifest)
       when is_binary(card_id) and card_id != "" do
    if manifest["plan_note"] || manifest["planNote"] do
      manifest
    else
      adapter =
        Application.get_env(
          :crucible,
          :kanban_adapter,
          Crucible.Kanban.DbAdapter
        )

      case adapter.get_card(card_id) do
        {:ok, card} ->
          meta = card.metadata || %{}

          manifest
          |> Map.put_new("plan_note", meta["planNote"])
          |> Map.put_new("plan_summary", meta["planSummary"])

        _ ->
          manifest
      end
    end
  end

  defp enrich_from_card(manifest), do: manifest

  # --- Helpers ---

  defp is_run_active?(run_id) do
    case Registry.lookup(Crucible.RunRegistry, run_id) do
      [{_pid, _meta}] -> true
      [] -> false
    end
  end

  defp run_workflow_type(run_id) do
    case Registry.lookup(Crucible.RunRegistry, run_id) do
      [{_pid, meta}] -> Map.get(meta || %{}, :workflow_type, "unknown")
      [] -> "unknown"
    end
  end

  defp list_running_runs_map do
    Registry.select(Crucible.RunRegistry, [
      {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$3"}}]}
    ])
    |> Map.new(fn {run_id, meta} ->
      meta = meta || %{}

      {run_id,
       %{
         run_id: run_id,
         workflow_type: Map.get(meta, :workflow_type, "unknown"),
         tenant_id: Map.get(meta, :tenant_id, "default"),
         started_at: Map.get(meta, :started_at)
       }}
    end)
  end

  defp write_run_manifest(runs_dir, manifest) do
    File.mkdir_p!(runs_dir)

    run_id =
      manifest["run_id"] || manifest["runId"] ||
        :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)

    # Write to distributed store
    safe_store_call(fn -> DistributedStore.put_run(run_id, manifest) end)

    # Also write to file for backwards compatibility
    path = Path.join(runs_dir, "#{run_id}.json")

    case Jason.encode(manifest, pretty: true) do
      {:ok, json} ->
        File.write!(path, json)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_run_manifest(path) do
    with {:ok, content} <- File.read(path),
         {:ok, manifest} <- Jason.decode(content),
         :ok <- validate_manifest(manifest, path) do
      {:ok, manifest}
    else
      {:error, _} = err -> err
    end
  end

  @valid_statuses ~w(pending running review done completed failed cancelled orphaned budget_paused)

  defp validate_manifest(manifest, path) when is_map(manifest) do
    run_id = extract_run_id(manifest)

    cond do
      is_nil(run_id) or run_id == "" ->
        Logger.warning("Orchestrator: skipping manifest #{path}: missing run_id")
        {:error, :missing_run_id}

      not is_binary(run_id) ->
        Logger.warning("Orchestrator: skipping manifest #{path}: run_id is not a string")
        {:error, :invalid_run_id}

      manifest["status"] && manifest["status"] not in @valid_statuses ->
        Logger.warning(
          "Orchestrator: skipping manifest #{path}: invalid status '#{manifest["status"]}'"
        )

        {:error, :invalid_status}

      true ->
        :ok
    end
  end

  defp validate_manifest(_not_a_map, path) do
    Logger.warning("Orchestrator: skipping manifest #{path}: not a JSON object")
    {:error, :not_a_map}
  end

  defp extract_run_id(manifest) do
    manifest["run_id"] || manifest["runId"] || manifest["id"]
  end

  # --- Cached disk manifest stats (30s TTL) ---

  @run_stats_ttl_ms 30_000

  defp ensure_run_stats_cache(state) do
    now = System.monotonic_time(:millisecond)
    last_refresh = Map.get(state, :run_stats_at, 0)

    if now - last_refresh < @run_stats_ttl_ms and Map.has_key?(state, :run_stats_cache) do
      {state.run_stats_cache, state}
    else
      {stats, recent} = scan_run_manifests(state.runs_dir)

      state =
        state
        |> Map.put(:run_stats_cache, stats)
        |> Map.put(:run_stats_recent, recent)
        |> Map.put(:run_stats_at, now)

      {stats, state}
    end
  end

  defp scan_run_manifests(runs_dir) do
    if File.dir?(runs_dir) do
      files =
        runs_dir
        |> File.ls!()
        |> Enum.filter(
          &(String.ends_with?(&1, ".json") and
              not String.ends_with?(&1, ".result.json") and
              not String.ends_with?(&1, ".dod.json") and
              not String.ends_with?(&1, ".signal.json") and
              &1 != "merge-result.json")
        )

      {counts, recent_acc} =
        Enum.reduce(files, {%{}, []}, fn file, {counts, recent} ->
          path = Path.join(runs_dir, file)

          case File.read(path) do
            {:ok, content} ->
              case Jason.decode(content) do
                {:ok, manifest} ->
                  status = manifest["status"] || "unknown"
                  counts = Map.update(counts, status, 1, &(&1 + 1))

                  entry = %{
                    id: manifest["runId"] || manifest["run_id"] || Path.rootname(file),
                    workflow_type:
                      manifest["workflowName"] || manifest["workflow_name"] || manifest["name"] ||
                        "unknown",
                    status: status_atom(status),
                    task_description:
                      manifest["taskDescription"] || manifest["task_description"] || "",
                    updated_at:
                      manifest["updatedAt"] || manifest["updated_at"] || manifest["createdAt"] ||
                        manifest["created_at"] || ""
                  }

                  {counts, [entry | recent]}

                _ ->
                  {counts, recent}
              end

            _ ->
              {counts, recent}
          end
        end)

      # Sort recent by updated_at desc, take top 20
      recent =
        recent_acc
        |> Enum.sort_by(& &1.updated_at, :desc)
        |> Enum.take(20)

      total = Enum.reduce(counts, 0, fn {_k, v}, acc -> acc + v end)

      stats = %{
        total: total,
        pending: Map.get(counts, "pending", 0),
        running: Map.get(counts, "running", 0),
        done: Map.get(counts, "done", 0) + Map.get(counts, "completed", 0),
        failed: Map.get(counts, "failed", 0),
        orphaned: Map.get(counts, "orphaned", 0),
        review: Map.get(counts, "review", 0),
        budget_paused: Map.get(counts, "budget_paused", 0),
        cancelled: Map.get(counts, "cancelled", 0)
      }

      {stats, recent}
    else
      {%{
         total: 0,
         pending: 0,
         running: 0,
         done: 0,
         failed: 0,
         orphaned: 0,
         review: 0,
         budget_paused: 0,
         cancelled: 0
       }, []}
    end
  rescue
    e ->
      Logger.warning("scan_run_manifests failed: #{inspect(e)}")

      {%{
         total: 0,
         pending: 0,
         running: 0,
         done: 0,
         failed: 0,
         orphaned: 0,
         review: 0,
         budget_paused: 0,
         cancelled: 0
       }, []}
  end

  defp status_atom(s), do: Status.to_atom(s)

  defp update_manifest_status(runs_dir, run_id, status, source_path) do
    # Update in distributed store
    case safe_store_call(fn -> DistributedStore.get_run(run_id) end) do
      {:ok, manifest} ->
        updated = Map.put(manifest, :status, status)
        safe_store_call(fn -> DistributedStore.put_run(run_id, updated) end)

      _ ->
        :ok
    end

    # Also update file for backwards compatibility
    # Try source_path first (actual file path from scan), fall back to run_id-based path
    path = source_path || Path.join(runs_dir, "#{run_id}.json")

    case read_run_manifest(path) do
      {:ok, manifest} ->
        updated = manifest |> Map.put("status", status) |> Map.delete("_source_path")

        case Jason.encode(updated, pretty: true) do
          {:ok, json} -> File.write(path, json)
          _ -> :ok
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # Safely call DistributedStore, catching exits if the GenServer isn't running.
  # Returns {:ok, result} on success for list calls, or the direct return for others.
  defp safe_store_call(fun) do
    if Application.get_env(:crucible, :distributed, false) do
      result = fun.()

      case result do
        list when is_list(list) -> {:ok, list}
        other -> other
      end
    else
      {:error, :store_unavailable}
    end
  catch
    :exit, {:noproc, _} -> {:error, :store_unavailable}
    :exit, reason -> {:error, reason}
  end

  # --- Distributed Dispatch ---

  defp ensure_pg_started do
    case :pg.start_link(@pg_scope) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp schedule_work_steal do
    Process.send_after(self(), :maybe_steal_work, @work_steal_interval_ms)
  end

  defp peer_orchestrators do
    :pg.get_members(@pg_scope, @pg_group)
    |> Enum.reject(&(&1 == self()))
  end

  # Non-blocking RPC wrapper: runs :rpc.call in a Task with yield/shutdown
  # so the Orchestrator GenServer is never blocked by stalled peers.
  defp rpc_with_timeout(target_node, mod, fun, args, timeout_ms \\ nil) do
    timeout = timeout_ms || distributed_rpc_timeout()

    task = Task.async(fn -> :rpc.call(target_node, mod, fun, args, timeout) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:badrpc, :timeout}
    end
  end

  defp distributed_rpc_timeout do
    Application.get_env(:crucible, :distributed_rpc_timeout_ms, 3_000)
  end

  # Determines the preferred node for a run based on working directory locality.
  # Checks which cluster nodes have that path locally accessible and picks the
  # least-loaded one. Falls back to the current node if no affinity signal exists.
  defp preferred_node_for_run(manifest) do
    working_dir = manifest["working_dir"] || manifest["workingDir"]

    if working_dir do
      # Check which nodes have the working directory locally mounted
      candidate_nodes =
        [node() | Node.list()]
        |> Enum.filter(fn n ->
          try do
            rpc_with_timeout(n, File, :dir?, [working_dir]) == true
          catch
            _, _ -> false
          end
        end)

      case candidate_nodes do
        [] ->
          node()

        candidates ->
          # Among candidates, pick the one with most available slots
          candidates
          |> Enum.map(fn n ->
            load =
              try do
                rpc_with_timeout(n, __MODULE__, :local_load_info, [])
              catch
                _, _ -> %{available_slots: 0}
              end

            case load do
              {:badrpc, _} -> {n, 0}
              info -> {n, Map.get(info, :available_slots, 0)}
            end
          end)
          |> Enum.max_by(fn {_n, slots} -> slots end)
          |> elem(0)
      end
    else
      node()
    end
  end

  @doc "Returns load info for this node (called via :rpc from peers)."
  def local_load_info do
    active = RunSupervisor.active_count()
    # Read max_concurrent from config; default 5
    max_concurrent =
      Application.get_env(:crucible, :max_concurrent_runs, 5)

    %{
      node: node(),
      active_runs: active,
      max_concurrent: max_concurrent,
      available_slots: max(max_concurrent - active, 0)
    }
  end

  # Work stealing: if this node is idle, query peer nodes for pending runs
  # and dispatch one locally.
  defp maybe_steal_work(state) do
    active = RunSupervisor.active_count()

    if active > @idle_threshold do
      state
    else
      peers = peer_orchestrators()

      if peers == [] do
        state
      else
        steal_from_peers(state, peers)
      end
    end
  end

  # Dispatch lock: prevents two nodes from dispatching the same run simultaneously.
  # Primary: Postgres advisory lock (atomic, cross-node safe).
  # Fallback: file-based exclusive write (for when DB is unavailable).
  defp acquire_dispatch_lock(lock_path) do
    run_id = Path.basename(lock_path, ".lock")
    lock_key = :erlang.phash2(run_id)

    case try_advisory_lock(lock_key) do
      {:ok, true} ->
        true

      _ ->
        # Fallback to file-based lock
        acquire_file_lock(lock_path)
    end
  end

  defp try_advisory_lock(lock_key) do
    Crucible.Repo.query("SELECT pg_try_advisory_lock($1)", [lock_key])
    |> case do
      {:ok, %{rows: [[true]]}} -> {:ok, true}
      {:ok, _} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :db_unavailable}
  catch
    :exit, _ -> {:error, :db_unavailable}
  end

  defp release_advisory_lock(lock_key) do
    Crucible.Repo.query("SELECT pg_advisory_unlock($1)", [lock_key])
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp acquire_file_lock(lock_path) do
    content = "#{node()}:#{System.system_time(:millisecond)}"

    case File.write(lock_path, content, [:exclusive]) do
      :ok -> true
      {:error, :eexist} -> stale_lock?(lock_path)
      {:error, _} -> false
    end
  end

  # A lock older than 60s is stale (node crashed mid-dispatch). Reclaim it.
  @lock_stale_ms 60_000
  defp stale_lock?(lock_path) do
    case File.stat(lock_path, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        age_ms = (System.os_time(:second) - mtime) * 1_000

        if age_ms > @lock_stale_ms do
          File.rm(lock_path)
          acquire_file_lock(lock_path)
        else
          false
        end

      _ ->
        false
    end
  end

  defp release_dispatch_lock(lock_path) do
    # Release both advisory and file locks
    run_id = Path.basename(lock_path, ".lock")
    lock_key = :erlang.phash2(run_id)
    release_advisory_lock(lock_key)
    File.rm(lock_path)
  end

  defp steal_from_peers(state, peers) do
    # Query each peer for pending runs, take the first available one
    timeout = distributed_rpc_timeout()

    stolen =
      Enum.find_value(peers, nil, fn peer_pid ->
        try do
          case GenServer.call(peer_pid, :pending_runs, timeout) do
            [manifest | _] -> manifest
            _ -> nil
          end
        catch
          :exit, _ -> nil
        end
      end)

    case stolen do
      nil ->
        state

      manifest ->
        run_id = extract_run_id(manifest)
        tenant_id = extract_tenant_id(manifest)

        Logger.info("Orchestrator: work steal — claiming run #{run_id} from peer on #{node()}")

        case ensure_tenant_ready(tenant_id) do
          :ok ->
            dispatch_run(state, manifest)

          {:error, reason} ->
            Logger.error(
              "Orchestrator: work steal failed for #{run_id}, tenant init error: #{inspect(reason)}"
            )

            state
        end
    end
  end

  # --- Startup cleanup ---

  # 30 days
  @trace_max_age_ms 30 * 24 * 60 * 60_000
  # 1 hour
  @signal_max_age_ms 60 * 60_000

  defp purge_stale_artifacts(runs_dir) do
    repo_root = Path.dirname(runs_dir)
    purge_stale_files(Path.join(repo_root, "logs/traces"), @trace_max_age_ms, "traces")

    purge_stale_files(
      Path.join([repo_root, "..", ".claude-flow", "signals"]) |> Path.expand(),
      @signal_max_age_ms,
      "signals"
    )
  rescue
    _ -> :ok
  end

  defp purge_stale_files(dir, max_age_ms, label) do
    if File.dir?(dir) do
      now = System.system_time(:millisecond)

      dir
      |> File.ls!()
      |> Enum.each(fn file ->
        path = Path.join(dir, file)

        case File.stat(path, time: :posix) do
          {:ok, %{mtime: mtime}} ->
            age_ms = now - mtime * 1000

            if age_ms > max_age_ms do
              File.rm(path)
            end

          _ ->
            :ok
        end
      end)

      Logger.debug("Orchestrator: purged stale #{label} from #{dir}")
    end
  rescue
    _ -> :ok
  end

  # Kill orphaned tmux sessions from dead workflow runs.
  # Only kills sessions matching the orch-* naming convention (workflow-spawned).
  # Checks whether the run is still active before killing — avoids killing
  # sessions for runs that are genuinely in progress.
  defp kill_orphaned_tmux_sessions do
    case System.cmd("tmux", ~w(list-sessions -F) ++ [~S"#{session_name}"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "orch-"))
        |> Enum.each(fn session_name ->
          # Extract run_id from session name: orch-{runId}-{phaseId}
          # Only kill if no RunServer is alive for this run
          run_id = extract_run_id_from_session(session_name)

          if run_id && !run_currently_active?(run_id) do
            System.cmd("tmux", ["kill-session", "-t", session_name], stderr_to_stdout: true)
            Logger.info("Orchestrator: killed orphaned tmux session #{session_name}")
          end
        end)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp extract_run_id_from_session("orch-" <> rest) do
    # Session name format: orch-{runId}-{phaseId}
    # Run IDs can contain hyphens, so we split from the right
    case String.split(rest, "-") do
      parts when length(parts) >= 2 ->
        # Drop the last part (phaseId like "phase-0" or "p0")
        # But phase IDs can also have hyphens... take the first segment as run_id
        # Actually, for safety just check if ANY active run's ID is a prefix of `rest`
        rest

      _ ->
        nil
    end
  end

  defp extract_run_id_from_session(_), do: nil

  defp run_currently_active?(run_id_hint) do
    case Registry.select(Crucible.RunRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}]) do
      run_ids when is_list(run_ids) ->
        Enum.any?(run_ids, fn rid -> String.contains?(run_id_hint, rid) end)

      _ ->
        false
    end
  end
end
