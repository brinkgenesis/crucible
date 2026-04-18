defmodule Crucible.ResultWriter do
  @moduledoc """
  GenServer for serialized run manifest I/O.
  Ensures only one process writes run results at a time.

  Provides a state machine for run status transitions with:
  - Validated transitions (only allowed state changes proceed)
  - Idempotency keys (duplicate requests are safely skipped)
  - Optimistic version locking (monotonic version increment on every write)
  - Atomic file writes (temp → rename to prevent partial reads)
  - Optional trace event emission via PubSub
  - Cleanup helpers for residual tasks and signal files
  """
  use GenServer

  require Logger

  alias Crucible.State.DistributedStore

  @version_conflict_retries 3
  @call_timeout 10_000

  # --- Allowed state transitions ---

  @allowed_transitions %{
    "pending" => MapSet.new(~w(running failed orphaned)),
    "running" => MapSet.new(~w(review done failed orphaned budget_paused)),
    "review" => MapSet.new(~w(done failed orphaned)),
    "failed" => MapSet.new(~w(running orphaned)),
    "done" => MapSet.new(~w(done)),
    "orphaned" => MapSet.new(~w(orphaned)),
    "budget_paused" => MapSet.new(~w(running failed orphaned))
  }

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Writes a run result to disk."
  @spec write_result(String.t(), map()) :: :ok
  def write_result(run_id, result) do
    GenServer.call(__MODULE__, {:write_result, run_id, result}, @call_timeout)
  end

  @doc "Reads a run manifest from disk."
  @spec read_run(String.t()) :: {:ok, map()} | {:error, :not_found | :decode_error}
  def read_run(run_id) do
    GenServer.call(__MODULE__, {:read_run, run_id}, @call_timeout)
  end

  @doc """
  Transitions run status with validation.
  Returns `{:ok, true}` if transitioned, `{:ok, false}` if idempotent skip.
  """
  @spec transition_run_status(String.t(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, term()}
  def transition_run_status(run_id, next_status, idempotency_key) do
    GenServer.call(__MODULE__, {:transition, run_id, next_status, idempotency_key}, @call_timeout)
  end

  @doc """
  Transitions run status and emits a trace event via PubSub.
  Delegates to `transition_run_status/3` and broadcasts on success.
  """
  @spec transition_run_status_with_trace(String.t(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, term()}
  def transition_run_status_with_trace(run_id, next_status, idempotency_key) do
    case transition_run_status(run_id, next_status, idempotency_key) do
      {:ok, true} = result ->
        Phoenix.PubSub.broadcast(
          Crucible.PubSub,
          "orchestrator:traces",
          {:trace_event,
           %{
             type: "run_status_transition",
             run_id: run_id,
             status: next_status,
             timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
           }}
        )

        result

      other ->
        other
    end
  end

  @doc """
  Syncs phase card progress to the kanban card.
  Updates the card's metadata with current phase statuses.
  """
  @spec sync_phase_cards(String.t(), map()) :: :ok | {:error, term()}
  def sync_phase_cards(card_id, phase_statuses) when is_binary(card_id) do
    GenServer.call(__MODULE__, {:sync_phase_cards, card_id, phase_statuses}, @call_timeout)
  end

  def sync_phase_cards(nil, _), do: :ok

  @doc """
  Moves a kanban card to a new column with trace emission.
  """
  @spec transition_card_column(String.t(), atom(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def transition_card_column(card_id, column, reason) do
    GenServer.call(__MODULE__, {:transition_card, card_id, column, reason}, @call_timeout)
  end

  @doc """
  Cleans up stuck in_progress tasks after a run ends.
  Reads task files from `~/.claude/tasks/{team_name}/` and marks
  any `in_progress` tasks as `completed`.

  Returns the number of tasks cleaned up.
  """
  @spec cleanup_residual_tasks(String.t(), map()) :: non_neg_integer()
  def cleanup_residual_tasks(team_name, _run_manifest) do
    tasks_dir = Path.expand("~/.claude/tasks/#{team_name}")

    if File.dir?(tasks_dir) do
      tasks_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.reduce(0, fn file, count ->
        path = Path.join(tasks_dir, file)

        case Jason.decode(File.read!(path)) do
          {:ok, %{"status" => "in_progress"} = task} ->
            updated = Map.put(task, "status", "completed")
            File.write!(path, Jason.encode!(updated, pretty: true))
            count + 1

          _ ->
            count
        end
      end)
    else
      0
    end
  rescue
    _ -> 0
  end

  @doc """
  Removes signal files (.wake, .task-status) for a run.
  Scans the signals directory for files matching the team name and removes them.

  Returns the number of signal files removed.
  """
  @spec cleanup_run_signals(String.t(), map()) :: non_neg_integer()
  def cleanup_run_signals(infra_home, run_manifest) do
    team_name =
      Map.get(run_manifest, "teamName") || Map.get(run_manifest, :team_name)

    if is_nil(team_name) do
      0
    else
      signals_dir = Path.join(infra_home, ".claude-flow/signals")

      if File.dir?(signals_dir) do
        signals_dir
        |> File.ls!()
        |> Enum.filter(fn f -> String.contains?(f, team_name) end)
        |> Enum.reduce(0, fn file, acc ->
          File.rm(Path.join(signals_dir, file))
          acc + 1
        end)
      else
        0
      end
    end
  rescue
    _ -> 0
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    runs_dir =
      case Keyword.get(opts, :runs_dir) do
        nil ->
          config = Application.get_env(:crucible, :orchestrator, [])
          repo_root = Keyword.get(config, :repo_root, File.cwd!())
          Path.join(repo_root, Keyword.get(config, :runs_dir, ".claude-flow/runs"))

        dir ->
          dir
      end

    File.mkdir_p!(runs_dir)
    Logger.info("ResultWriter started (runs_dir=#{runs_dir})")
    {:ok, %{runs_dir: runs_dir, last_transition_keys: %{}}}
  end

  @impl true
  def handle_call({:write_result, run_id, result}, _from, state) do
    # Delegate to distributed store, fall back to file if unavailable
    case safe_store_call(fn -> DistributedStore.put_result(run_id, result) end) do
      :ok ->
        Logger.info("Wrote result for run #{run_id} (distributed)")

      {:error, reason} ->
        Logger.info(
          "DistributedStore unavailable for result #{run_id}: #{inspect(reason)}, falling back to file"
        )

        write_result_to_file(run_id, result, state.runs_dir)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:read_run, run_id}, _from, state) do
    result =
      case safe_store_call(fn -> DistributedStore.get_run(run_id) end) do
        {:ok, manifest} ->
          {:ok, manifest}

        {:error, :not_found} ->
          # Fall back to file-based read
          read_run_from_file(run_id, state.runs_dir)

        {:error, _} ->
          # Store unavailable, fall back to file
          read_run_from_file(run_id, state.runs_dir)
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:transition, run_id, next_status, idempotency_key}, _from, state) do
    if Map.get(state.last_transition_keys, run_id) == idempotency_key do
      {:reply, {:ok, false}, state}
    else
      result = do_transition(run_id, next_status, idempotency_key, state)

      new_keys =
        case result do
          {:ok, true} -> Map.put(state.last_transition_keys, run_id, idempotency_key)
          _ -> state.last_transition_keys
        end

      {:reply, result, %{state | last_transition_keys: new_keys}}
    end
  end

  @impl true
  def handle_call({:sync_phase_cards, card_id, phase_statuses}, _from, state) do
    result = do_sync_phase_cards(card_id, phase_statuses)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:transition_card, card_id, column, reason}, _from, state) do
    result = do_transition_card(card_id, column, reason)
    {:reply, result, state}
  end

  # --- Private: card operations ---

  defp do_sync_phase_cards(card_id, phase_statuses) do
    do_sync_phase_cards(card_id, phase_statuses, 0)
  end

  defp do_sync_phase_cards(card_id, _phase_statuses, attempt)
       when attempt >= @version_conflict_retries do
    Logger.warning("ResultWriter: version conflict exhausted for card #{card_id}")
    {:error, :version_conflict}
  end

  defp do_sync_phase_cards(card_id, phase_statuses, attempt) do
    tracker = kanban_tracker()

    case tracker.get_card(card_id) do
      {:ok, card} ->
        metadata =
          card.metadata
          |> Map.put("phase_statuses", phase_statuses)
          |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

        case tracker.update_card(card_id, %{metadata: metadata}, card.version) do
          {:error, :version_conflict} ->
            Logger.debug(
              "ResultWriter: version conflict on card #{card_id}, retry #{attempt + 1}"
            )

            do_sync_phase_cards(card_id, phase_statuses, attempt + 1)

          other ->
            other
        end

      {:error, _} = err ->
        Logger.warning("ResultWriter: failed to sync phases to card #{card_id}: #{inspect(err)}")
        err
    end
  rescue
    e ->
      Logger.warning("ResultWriter: sync_phase_cards error: #{inspect(e)}")
      {:error, e}
  end

  defp do_transition_card(card_id, column, reason) do
    tracker = kanban_tracker()

    case tracker.get_card(card_id) do
      {:ok, card} ->
        case tracker.move_card(card_id, column, card.version) do
          {:ok, _} = ok ->
            Phoenix.PubSub.broadcast(
              Crucible.PubSub,
              "orchestrator:traces",
              {:trace_event,
               %{
                 type: "card_column_transition",
                 card_id: card_id,
                 column: to_string(column),
                 reason: reason,
                 timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
               }}
            )

            ok

          err ->
            err
        end

      err ->
        err
    end
  rescue
    e ->
      Logger.warning("ResultWriter: transition_card error: #{inspect(e)}")
      {:error, e}
  end

  defp kanban_tracker do
    Application.get_env(
      :crucible,
      :kanban_tracker,
      Crucible.Kanban.DbAdapter
    )
  end

  # --- Private: distributed store delegation with file fallback ---

  defp do_transition(run_id, next_status, idempotency_key, state) do
    # Try distributed store first, fall back to file-based transition
    case safe_store_call(fn -> DistributedStore.get_run(run_id) end) do
      {:ok, manifest} ->
        transition_manifest(run_id, manifest, next_status, idempotency_key, :distributed)

      {:error, :not_found} ->
        transition_from_file(run_id, next_status, idempotency_key, state)

      {:error, _} ->
        transition_from_file(run_id, next_status, idempotency_key, state)
    end
  end

  defp transition_manifest(run_id, manifest, next_status, idempotency_key, source) do
    current_status = manifest[:status] || manifest["status"] || "pending"
    current_status = to_string(current_status)
    allowed = Map.get(@allowed_transitions, current_status, MapSet.new())

    if MapSet.member?(allowed, next_status) do
      current_version = manifest[:version] || manifest["version"] || 0

      updated =
        manifest
        |> Map.put(:status, next_status)
        |> Map.put("status", next_status)
        |> Map.put(:version, current_version + 1)
        |> Map.put("version", current_version + 1)
        |> Map.put("updatedAt", DateTime.utc_now() |> DateTime.to_iso8601())
        |> Map.put("lastTransitionKey", idempotency_key)

      case source do
        :distributed ->
          safe_store_call(fn -> DistributedStore.put_run(run_id, updated) end)

        :file ->
          :ok
      end

      Logger.info(
        "ResultWriter: transitioned run #{run_id} from #{current_status} to #{next_status} (v#{current_version + 1})"
      )

      {:ok, true}
    else
      Logger.warning(
        "ResultWriter: invalid transition #{current_status} -> #{next_status} for run #{run_id}"
      )

      {:error, {:invalid_transition, current_status, next_status}}
    end
  end

  defp transition_from_file(run_id, next_status, idempotency_key, state) do
    path = Path.join(state.runs_dir, "#{run_id}.manifest.json")

    with {:ok, content} <- File.read(path),
         {:ok, manifest} <- Jason.decode(content) do
      case transition_manifest(run_id, manifest, next_status, idempotency_key, :file) do
        {:ok, true} = result ->
          # Write updated manifest back to file
          current_version = Map.get(manifest, "version", 0)

          updated =
            manifest
            |> Map.put("status", next_status)
            |> Map.put("version", current_version + 1)
            |> Map.put("updatedAt", DateTime.utc_now() |> DateTime.to_iso8601())
            |> Map.put("lastTransitionKey", idempotency_key)

          atomic_write!(path, Jason.encode!(updated, pretty: true))
          result

        other ->
          other
      end
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_result_to_file(run_id, result, runs_dir) do
    path = Path.join(runs_dir, "#{run_id}.result.json")

    case Jason.encode(result, pretty: true) do
      {:ok, json} ->
        atomic_write!(path, json)
        Logger.info("Wrote result for run #{run_id} (file)")

      {:error, reason} ->
        Logger.error("Failed to encode result for run #{run_id}: #{inspect(reason)}")
    end
  end

  defp read_run_from_file(run_id, runs_dir) do
    path = Path.join(runs_dir, "#{run_id}.manifest.json")

    if File.exists?(path) do
      case Jason.decode(File.read!(path)) do
        {:ok, manifest} -> {:ok, manifest}
        {:error, _} -> {:error, :decode_error}
      end
    else
      {:error, :not_found}
    end
  end

  # Safely call DistributedStore, catching exits if the GenServer isn't running.
  defp safe_store_call(fun) do
    fun.()
  catch
    :exit, {:noproc, _} -> {:error, :store_unavailable}
    :exit, reason -> {:error, reason}
  end

  # Atomic write: write to temp file then rename (POSIX atomic rename).
  # Prevents partial reads from concurrent readers.
  defp atomic_write!(path, data) do
    dir = Path.dirname(path)
    tmp = Path.join(dir, ".tmp-#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}")

    try do
      File.write!(tmp, data)
      File.rename!(tmp, path)
    rescue
      # Fallback for cross-device or permission issues
      _ ->
        File.rm(tmp)
        File.write!(path, data)
    end
  end
end
