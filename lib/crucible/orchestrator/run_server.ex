defmodule Crucible.Orchestrator.RunServer do
  @moduledoc """
  Per-run GenServer — each dispatched workflow run gets its own process with:

  1. Registry-based naming via `{:via, Registry, {RunRegistry, run_id}}`
  2. Isolated state: phases, retries, timestamps, budget status
  3. Spawns a Task to execute `AgentRunner.run/3`
  4. Monitors the Task and handles exit (success, failure, budget pause)
  5. Self-retries on failure with exponential backoff + jitter
  6. Reports lifecycle events to the Orchestrator and PubSub
  7. Stops itself when the run completes or exhausts retries

  Started by `RunSupervisor` (DynamicSupervisor). Looked up by run_id
  via the `RunRegistry` — no pid required by callers.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Crucible.{AgentRunner, Events, PhasePersistence, Repo}
  alias Crucible.Schema.WorkflowRun
  alias Crucible.Kanban.DbAdapter
  alias Crucible.Telemetry.Spans

  @max_retry_backoff_ms 120_000
  @base_retry_backoff_ms 30_000

  # --- Public API (run_id-routed via Registry) ---

  @doc """
  Starts a RunServer registered in the RunRegistry.

  Accepts a keyword list with:
    - `:run` — a `%Crucible.Types.Run{}` struct (required)
    - `:run_opts` — options forwarded to `AgentRunner.run/3`
    - `:max_retries` — max retry attempts (default 3)
    - `:orchestrator_pid` — pid to receive lifecycle messages
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    run = Keyword.fetch!(opts, :run)

    meta = %{
      workflow_type: run.workflow_type,
      started_at: System.monotonic_time(:millisecond)
    }

    name = {:via, Registry, {Crucible.RunRegistry, run.id, meta}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Get a state snapshot for this run."
  @spec get_info(String.t()) :: map() | {:error, :not_found}
  def get_info(run_id) do
    safe_call(run_id, :get_info)
  end

  @doc "Get the full run state (used internally by Orchestrator)."
  @spec get_run_state(String.t()) :: map() | {:error, :not_found}
  def get_run_state(run_id) do
    safe_call(run_id, :get_run_state)
  end

  @doc "Get the current status atom for this run."
  @spec get_status(String.t()) :: atom() | {:error, :not_found}
  def get_status(run_id) do
    safe_call(run_id, :get_status)
  end

  @doc "Cancel the run, stopping the agent task and the server."
  @spec cancel(String.t() | pid()) :: :ok | {:error, :not_found}
  def cancel(run_id) when is_binary(run_id) do
    safe_call(run_id, :cancel)
  end

  def cancel(pid) when is_pid(pid) do
    GenServer.call(pid, :cancel)
  end

  @doc "Check if a run is alive in the registry."
  @spec alive?(String.t()) :: boolean()
  def alive?(run_id) do
    case Registry.lookup(Crucible.RunRegistry, run_id) do
      [{_pid, _meta}] -> true
      [] -> false
    end
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    run = Keyword.fetch!(opts, :run)
    run_opts = Keyword.get(opts, :run_opts, [])
    max_retries = Keyword.get(opts, :max_retries, 3)
    orchestrator_pid = Keyword.get(opts, :orchestrator_pid, nil)

    started_at = System.monotonic_time(:millisecond)

    # Trap exits so terminate/2 fires on shutdown
    Process.flag(:trap_exit, true)

    state = %{
      run: run,
      run_opts: run_opts,
      max_retries: max_retries,
      retry_count: 0,
      started_at: started_at,
      task_ref: nil,
      task_pid: nil,
      orchestrator_pid: orchestrator_pid,
      status: :starting
    }

    Logger.info("RunServer: started for run #{run.id} (#{run.workflow_type})")

    # Start execution immediately
    {:ok, state, {:continue, :execute}}
  end

  @impl true
  def handle_continue(:execute, state) do
    state = spawn_task(state)
    {:noreply, %{state | status: :running}}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      run_id: state.run.id,
      workflow_type: state.run.workflow_type,
      started_at: state.started_at,
      status: state.status,
      retry_count: state.retry_count,
      max_retries: state.max_retries,
      elapsed_ms: System.monotonic_time(:millisecond) - state.started_at
    }

    {:reply, info, state}
  end

  def handle_call(:get_run_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call(:cancel, _from, state) do
    state = kill_task(state)
    elapsed = System.monotonic_time(:millisecond) - state.started_at

    emit_telemetry(:stop, %{duration: elapsed}, %{
      run_id: state.run.id,
      workflow_type: state.run.workflow_type,
      status: :cancelled
    })

    Logger.info("RunServer: cancelled run #{state.run.id} after #{elapsed}ms")
    {:stop, :normal, :ok, %{state | status: :cancelled}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    state = handle_task_exit(state, reason)

    case state.status do
      :retrying ->
        {:noreply, state}

      _terminal ->
        {:stop, :normal, state}
    end
  end

  def handle_info({:agent_update, _run_id, %{type: :budget_paused}}, state) do
    Logger.info("RunServer: run #{state.run.id} paused (budget exceeded)")

    Phoenix.PubSub.broadcast(
      Crucible.PubSub,
      "orchestrator:updates",
      {:agent_update, state.run.id, %{type: :budget_paused}}
    )

    {:noreply, %{state | status: :budget_paused}}
  end

  def handle_info({:agent_update, run_id, %{type: :failed} = update}, state) do
    Phoenix.PubSub.broadcast(
      Crucible.PubSub,
      "orchestrator:updates",
      {:agent_update, run_id, update}
    )

    {:noreply, %{state | status: :failed}}
  end

  def handle_info({:agent_update, run_id, update}, state) do
    Phoenix.PubSub.broadcast(
      Crucible.PubSub,
      "orchestrator:updates",
      {:agent_update, run_id, update}
    )

    {:noreply, state}
  end

  def handle_info(:retry, state) do
    Logger.info(
      "RunServer: retrying run #{state.run.id} (attempt #{state.retry_count}/#{state.max_retries})"
    )

    reset_manifest_phases(state)
    state = spawn_task(state)
    {:noreply, %{state | status: :running}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    # Kill any in-flight agent task
    kill_task(state)

    # Kill any orphaned tmux sessions for this run's phases
    kill_run_tmux_sessions(state.run)

    level = if reason in [:normal, :shutdown], do: :info, else: :warning

    Logger.log(
      level,
      "RunServer: terminating run #{state.run.id} " <>
        "(status=#{state.status}, reason=#{inspect(reason)})"
    )

    :ok
  end

  # --- Private ---

  defp safe_call(run_id, msg) do
    case Registry.lookup(Crucible.RunRegistry, run_id) do
      [{pid, _meta}] -> GenServer.call(pid, msg)
      [] -> {:error, :not_found}
    end
  end

  defp spawn_task(state) do
    run = state.run
    run_opts = state.run_opts
    server_pid = self()

    Spans.with_span("run.start", %{"run.id" => run.id, "run.workflow" => run.workflow_type}, fn ->
      :ok
    end)

    emit_telemetry(:start, %{system_time: System.system_time(:millisecond)}, %{
      run_id: run.id,
      workflow_type: run.workflow_type
    })

    # Orphan detection: if the card was deleted, skip execution.
    # Only runs when card_id is available in opts (from manifest dispatch).
    orphan_card_id = Keyword.get(run_opts, :card_id)

    if is_binary(orphan_card_id) and orphan_card_id != "" do
      if is_nil(Repo.get(Crucible.Schema.Card, orphan_card_id)) do
        Logger.warning("RunServer: card #{orphan_card_id} deleted — orphaning run #{run.id}")
        sync_run_to_db(run.id, "orphaned")
        exit(:orphaned)
      end
    end

    # Persist phase start to DB for crash recovery + kanban visibility
    phase_index = state.retry_count
    PhasePersistence.record_phase_start(run.id, phase_index)
    sync_run_to_db(run.id, "running")
    move_card_column(run.id, "in_progress")

    {:ok, pid} =
      Task.Supervisor.start_child(
        Crucible.TaskSupervisor,
        fn ->
          Events.broadcast_run_event(run.id, :started, %{workflow_type: run.workflow_type})

          case AgentRunner.run(run, server_pid, run_opts) do
            {:ok, result} ->
              PhasePersistence.record_run_complete(run.id)
              Events.broadcast_run_event(run.id, :completed, %{result: result})
              send(server_pid, {:agent_update, run.id, %{type: :completed, result: result}})

            {:error, :budget_paused} ->
              Events.broadcast_run_event(run.id, :budget_paused)
              send(server_pid, {:agent_update, run.id, %{type: :budget_paused}})
              exit(:budget_paused)

            {:error, reason} = result ->
              PhasePersistence.record_run_failed(run.id)

              Events.broadcast_run_event(run.id, :failed, %{
                workflow_type: run.workflow_type,
                reason: inspect(reason)
              })

              send(server_pid, {:agent_update, run.id, %{type: :failed, reason: reason}})
              exit({:run_failed, result})
          end
        end
      )

    ref = Process.monitor(pid)
    %{state | task_pid: pid, task_ref: ref}
  end

  defp handle_task_exit(state, :normal) do
    elapsed = System.monotonic_time(:millisecond) - state.started_at
    Logger.info("RunServer: run #{state.run.id} completed in #{elapsed}ms")

    Spans.with_span(
      "run.complete",
      %{"run.id" => state.run.id, "run.workflow" => state.run.workflow_type},
      fn ->
        Spans.record_event("run.completed", %{"duration_ms" => elapsed})
      end
    )

    update_manifest_status(state, "done")
    sync_run_to_db(state.run.id, "done")
    move_card_column(state.run.id, "done")

    Crucible.SelfImprovement.trigger(state.run.id)

    emit_telemetry(:stop, %{duration: elapsed}, %{
      run_id: state.run.id,
      workflow_type: state.run.workflow_type,
      status: :completed
    })

    notify_orchestrator(state, :completed)
    %{state | status: :completed}
  end

  defp handle_task_exit(state, :budget_paused) do
    elapsed = System.monotonic_time(:millisecond) - state.started_at
    Logger.info("RunServer: run #{state.run.id} paused after #{elapsed}ms (budget exceeded)")
    update_manifest_status(state, "budget_paused")

    emit_telemetry(:stop, %{duration: elapsed}, %{
      run_id: state.run.id,
      workflow_type: state.run.workflow_type,
      status: :budget_paused
    })

    notify_orchestrator(state, :budget_paused)
    %{state | status: :budget_paused}
  end

  defp handle_task_exit(state, reason) do
    elapsed = System.monotonic_time(:millisecond) - state.started_at
    Logger.error("RunServer: run #{state.run.id} failed after #{elapsed}ms: #{inspect(reason)}")

    if state.retry_count < state.max_retries do
      backoff = retry_backoff_ms(state.retry_count)

      Logger.info(
        "RunServer: scheduling retry #{state.retry_count + 1}/#{state.max_retries} " <>
          "for #{state.run.id} in #{backoff}ms"
      )

      Spans.record_event("run.retry", %{
        "run.id" => state.run.id,
        "run.workflow" => state.run.workflow_type,
        "retry.attempt" => state.retry_count + 1,
        "retry.max" => state.max_retries
      })

      emit_telemetry(:stop, %{duration: elapsed}, %{
        run_id: state.run.id,
        workflow_type: state.run.workflow_type,
        status: :retrying,
        reason: reason
      })

      Process.send_after(self(), :retry, backoff)

      notify_orchestrator(state, {:failed_retrying, state.retry_count + 1})

      %{
        state
        | retry_count: state.retry_count + 1,
          status: :retrying,
          task_ref: nil,
          task_pid: nil
      }
    else
      Logger.warning("RunServer: run #{state.run.id} exhausted #{state.max_retries} retries")
      update_manifest_status(state, "failed")
      sync_run_to_db(state.run.id, "failed")
      move_card_column(state.run.id, "unassigned")
      notify_orchestrator(state, :exhausted)
      Crucible.SelfImprovement.trigger(state.run.id)
      spawn(fn -> Crucible.RunFailureHandler.create_inbox_item(state.run.id) end)

      emit_telemetry(:stop, %{duration: elapsed}, %{
        run_id: state.run.id,
        workflow_type: state.run.workflow_type,
        status: :failed,
        reason: reason
      })

      %{state | status: :failed}
    end
  end

  defp kill_task(%{task_pid: nil} = state), do: state

  defp kill_task(%{task_pid: pid} = state) do
    if Process.alive?(pid) do
      Task.Supervisor.terminate_child(Crucible.TaskSupervisor, pid)
    end

    %{state | task_pid: nil, task_ref: nil}
  end

  defp notify_orchestrator(%{orchestrator_pid: nil}, _event), do: :ok

  defp notify_orchestrator(%{orchestrator_pid: pid, run: run}, event) do
    send(pid, {:run_lifecycle, run.id, event})
  end

  defp retry_backoff_ms(retry_count) do
    base = @base_retry_backoff_ms * :math.pow(2, retry_count)
    jitter = :rand.uniform(round(base * 0.2))
    min(round(base) + jitter, @max_retry_backoff_ms)
  end

  defp emit_telemetry(event, measurements, metadata) do
    :telemetry.execute([:orchestrator, :run, event], measurements, metadata)
  end

  defp reset_manifest_phases(state) do
    runs_dir = Keyword.get(state.run_opts, :runs_dir)

    if runs_dir do
      path = Path.join(runs_dir, "#{state.run.id}.json")

      with {:ok, content} <- File.read(path),
           {:ok, manifest} <- Jason.decode(content) do
        phases = manifest["phases"] || []
        reset = Enum.map(phases, &Map.put(&1, "status", "pending"))
        updated = Map.put(manifest, "phases", reset)

        case Jason.encode(updated, pretty: true) do
          {:ok, json} -> File.write(path, json)
          _ -> :ok
        end
      end
    end
  rescue
    _ -> :ok
  end

  defp update_manifest_status(state, status) do
    runs_dir = Keyword.get(state.run_opts, :runs_dir)

    if runs_dir do
      path = Path.join(runs_dir, "#{state.run.id}.json")

      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, manifest} ->
              updated = Map.put(manifest, "status", status)

              case Jason.encode(updated, pretty: true) do
                {:ok, json} -> File.write(path, json)
                _ -> :ok
              end

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    end
  rescue
    _ -> :ok
  end

  # Sync run status to the workflow_runs DB table so the kanban and dashboard
  # can read it without falling back to file-based manifests.
  defp sync_run_to_db(run_id, status) do
    case Repo.get(WorkflowRun, run_id) do
      nil ->
        # Run was never inserted — read manifest for required fields
        config = Application.get_env(:crucible, :orchestrator, [])
        repo_root = Keyword.get(config, :repo_root, File.cwd!())
        manifest_path = Path.join([repo_root, ".claude-flow", "runs", "#{run_id}.json"])

        manifest_attrs =
          case File.read(manifest_path) do
            {:ok, content} ->
              case Jason.decode(content) do
                {:ok, m} ->
                  %{
                    card_id: m["cardId"] || m["card_id"],
                    workflow_name: m["workflowName"] || m["workflow_name"] || "unknown",
                    task_description: m["taskDescription"] || m["task_description"] || "",
                    execution_type: m["executionType"] || m["execution_type"] || "subscription",
                    workspace_path: m["workspace_path"] || m["workspacePath"],
                    version: m["version"] || 1
                  }

                _ ->
                  %{workflow_name: "unknown", task_description: "", version: 1}
              end

            _ ->
              %{workflow_name: "unknown", task_description: "", version: 1}
          end

        %WorkflowRun{run_id: run_id}
        |> Ecto.Changeset.change(
          Map.merge(manifest_attrs, %{
            status: status,
            updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })
        )
        |> Repo.insert!(on_conflict: {:replace, [:status, :updated_at]}, conflict_target: :run_id)

      run ->
        run
        |> Ecto.Changeset.change(%{
          status: status,
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update!()
    end

    Logger.debug("RunServer: synced run #{run_id} status=#{status} to DB")
  rescue
    e ->
      Logger.warning("RunServer: DB sync failed for #{run_id}: #{Exception.message(e)}")
  end

  # Move the card's kanban column based on the run's terminal status.
  # Includes ownership guard: only move if the card's run_id still matches
  # this run (prevents stale failed runs from overwriting cards reassigned to new runs).
  # Also prevents backward transitions (e.g. review → in_progress) since the TS
  # executor may advance the card to "review" during the pr-shepherd phase.
  @column_order %{"unassigned" => 0, "todo" => 1, "in_progress" => 2, "review" => 3, "done" => 4}

  defp move_card_column(run_id, column) do
    case Crucible.WorkflowPersistence.get_card_id(run_id) do
      nil ->
        :ok

      card_id when is_binary(card_id) ->
        card = Repo.get(Crucible.Schema.Card, card_id)

        cond do
          is_nil(card) ->
            :ok

          not (is_nil(card.run_id) or card.run_id == run_id) ->
            Logger.debug(
              "RunServer: skipped card move — card #{card_id} owned by run #{card.run_id}, not #{run_id}"
            )

          Map.get(@column_order, column, 0) <= Map.get(@column_order, card.column, 0) and
              column != "done" ->
            Logger.debug(
              "RunServer: skipped backward card move #{card.column} → #{column} for card #{card_id}"
            )

          true ->
            DbAdapter.update_card(card_id, %{column: column})
            Logger.debug("RunServer: moved card #{card_id} to column=#{column}")
        end

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("RunServer: card move failed for #{run_id}: #{Exception.message(e)}")
  end

  # Kill all tmux sessions associated with this run's phases.
  # Session names are deterministic: orch-{runId}-{phaseId}
  defp kill_run_tmux_sessions(run) do
    clean_run = String.replace(run.id, ~r/[^a-zA-Z0-9_-]/, "")

    Enum.each(run.phases, fn phase ->
      clean_phase = String.replace(phase.id, ~r/[^a-zA-Z0-9_-]/, "")
      session_name = "orch-#{clean_run}-#{clean_phase}"

      case System.cmd("tmux", ["has-session", "-t", session_name], stderr_to_stdout: true) do
        {_, 0} ->
          System.cmd("tmux", ["kill-session", "-t", session_name], stderr_to_stdout: true)
          Logger.info("RunServer: killed tmux session #{session_name}")

        _ ->
          :ok
      end
    end)
  rescue
    _ -> :ok
  end
end
