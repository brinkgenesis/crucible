defmodule Crucible.ResultStore do
  @moduledoc """
  ETS-backed state store for run manifests and phase results.

  Replaces file I/O on the hot path with in-memory ETS tables while keeping
  the state machine logic (allowed transitions, idempotency keys, version locking).
  ResultWriter becomes the optional persistence layer that snapshots to disk.

  ## Tables

  - `:result_store_manifests` — `{run_id, manifest_map}`
  - `:result_store_results` — `{run_id, result_map}`
  - `:result_store_idempotency` — `{run_id, last_idempotency_key}`
  """
  use GenServer

  require Logger

  @manifest_table :result_store_manifests
  @result_table :result_store_results
  @idempotency_table :result_store_idempotency

  @snapshot_interval_ms 30_000

  # Explicit call timeout — transition serializes through GenServer for atomicity;
  # involves ETS reads/writes but no I/O, so 15s covers any backpressure.
  @call_timeout 15_000

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

  @doc "Stores a run result in ETS."
  @spec put_result(String.t(), map()) :: :ok
  def put_result(run_id, result) do
    :ets.insert(@result_table, {run_id, result})
    :ok
  end

  @doc "Retrieves a run result from ETS."
  @spec get_result(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_result(run_id) do
    case :ets.lookup(@result_table, run_id) do
      [{^run_id, result}] -> {:ok, result}
      [] -> {:error, :not_found}
    end
  end

  @doc "Stores a run manifest in ETS."
  @spec put_manifest(String.t(), map()) :: :ok
  def put_manifest(run_id, manifest) do
    :ets.insert(@manifest_table, {run_id, manifest})
    :ok
  end

  @doc "Retrieves a run manifest from ETS."
  @spec get_manifest(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_manifest(run_id) do
    case :ets.lookup(@manifest_table, run_id) do
      [{^run_id, manifest}] -> {:ok, manifest}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Transitions run status with validation, idempotency, and version locking.

  Returns `{:ok, true}` on success, `{:ok, false}` on idempotent skip,
  or `{:error, reason}` on invalid transition or missing manifest.
  """
  @spec transition(String.t(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, term()}
  def transition(run_id, next_status, idempotency_key) do
    # Idempotency check (lock-free read)
    case :ets.lookup(@idempotency_table, run_id) do
      [{^run_id, ^idempotency_key}] ->
        {:ok, false}

      _ ->
        # Serialize transitions through GenServer for atomicity
        GenServer.call(__MODULE__, {:transition, run_id, next_status, idempotency_key}, @call_timeout)
    end
  end

  @doc "Returns all run IDs that have manifests."
  @spec list_run_ids() :: [String.t()]
  def list_run_ids do
    :ets.select(@manifest_table, [{{:"$1", :_}, [], [:"$1"]}])
  end

  @doc "Deletes a run's manifest, result, and idempotency key from ETS."
  @spec delete_run(String.t()) :: :ok
  def delete_run(run_id) do
    :ets.delete(@manifest_table, run_id)
    :ets.delete(@result_table, run_id)
    :ets.delete(@idempotency_table, run_id)
    :ok
  end

  @doc "Returns all manifests as a list of `{run_id, manifest}` tuples."
  @spec all_manifests() :: [{String.t(), map()}]
  def all_manifests do
    :ets.tab2list(@manifest_table)
  end

  @doc "Returns all results as a list of `{run_id, result}` tuples."
  @spec all_results() :: [{String.t(), map()}]
  def all_results do
    :ets.tab2list(@result_table)
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    # Create ETS tables owned by this GenServer
    :ets.new(@manifest_table, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@result_table, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@idempotency_table, [:set, :public, :named_table, read_concurrency: true])

    snapshot_interval = Keyword.get(opts, :snapshot_interval_ms, @snapshot_interval_ms)

    # Load existing manifests/results from disk into ETS
    runs_dir = resolve_runs_dir(opts)
    load_from_disk(runs_dir)

    # Schedule periodic snapshots
    if snapshot_interval > 0 do
      Process.send_after(self(), :snapshot, snapshot_interval)
    end

    Logger.info("ResultStore started (runs_dir=#{runs_dir})")

    {:ok,
     %{
       runs_dir: runs_dir,
       snapshot_interval_ms: snapshot_interval
     }}
  end

  @impl true
  def handle_call({:transition, run_id, next_status, idempotency_key}, _from, state) do
    # Double-check idempotency under lock
    case :ets.lookup(@idempotency_table, run_id) do
      [{^run_id, ^idempotency_key}] ->
        {:reply, {:ok, false}, state}

      _ ->
        result = do_transition(run_id, next_status, idempotency_key)
        {:reply, result, state}
    end
  end

  @impl true
  def handle_info(:snapshot, state) do
    snapshot_to_disk(state.runs_dir)

    if state.snapshot_interval_ms > 0 do
      Process.send_after(self(), :snapshot, state.snapshot_interval_ms)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private: state machine ---

  defp do_transition(run_id, next_status, idempotency_key) do
    case :ets.lookup(@manifest_table, run_id) do
      [{^run_id, manifest}] ->
        current_status = Map.get(manifest, "status", "pending")
        allowed = Map.get(@allowed_transitions, current_status, MapSet.new())

        if MapSet.member?(allowed, next_status) do
          current_version = Map.get(manifest, "version", 0)

          updated =
            manifest
            |> Map.put("status", next_status)
            |> Map.put("version", current_version + 1)
            |> Map.put("updatedAt", DateTime.utc_now() |> DateTime.to_iso8601())
            |> Map.put("lastTransitionKey", idempotency_key)

          :ets.insert(@manifest_table, {run_id, updated})
          :ets.insert(@idempotency_table, {run_id, idempotency_key})

          Logger.info(
            "ResultStore: transitioned run #{run_id} from #{current_status} to #{next_status} (v#{current_version + 1})"
          )

          {:ok, true}
        else
          Logger.warning(
            "ResultStore: invalid transition #{current_status} -> #{next_status} for run #{run_id}"
          )

          {:error, {:invalid_transition, current_status, next_status}}
        end

      [] ->
        {:error, :not_found}
    end
  end

  # --- Private: disk I/O ---

  defp load_from_disk(runs_dir) do
    if File.dir?(runs_dir) do
      runs_dir
      |> File.ls!()
      |> Enum.each(fn file ->
        path = Path.join(runs_dir, file)

        cond do
          String.ends_with?(file, ".manifest.json") ->
            run_id = String.replace_suffix(file, ".manifest.json", "")
            load_json_to_table(path, run_id, @manifest_table)

          String.ends_with?(file, ".result.json") ->
            run_id = String.replace_suffix(file, ".result.json", "")
            load_json_to_table(path, run_id, @result_table)

          true ->
            :ok
        end
      end)
    end
  rescue
    e ->
      Logger.warning("ResultStore: failed to load from disk: #{inspect(e)}")
  end

  defp load_json_to_table(path, run_id, table) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> :ets.insert(table, {run_id, data})
          _ -> Logger.warning("ResultStore: failed to decode #{path}")
        end

      _ ->
        :ok
    end
  end

  @doc false
  def snapshot_to_disk(runs_dir) do
    File.mkdir_p!(runs_dir)

    # Snapshot manifests
    :ets.tab2list(@manifest_table)
    |> Enum.each(fn {run_id, manifest} ->
      path = Path.join(runs_dir, "#{run_id}.manifest.json")
      atomic_write(path, manifest)
    end)

    # Snapshot results
    :ets.tab2list(@result_table)
    |> Enum.each(fn {run_id, result} ->
      path = Path.join(runs_dir, "#{run_id}.result.json")
      atomic_write(path, result)
    end)

    Logger.debug("ResultStore: snapshot complete")
  rescue
    e -> Logger.warning("ResultStore: snapshot failed: #{inspect(e)}")
  end

  defp atomic_write(path, data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} ->
        dir = Path.dirname(path)

        tmp =
          Path.join(dir, ".tmp-#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}")

        try do
          File.write!(tmp, json)
          File.rename!(tmp, path)
        rescue
          _ ->
            File.rm(tmp)
            File.write!(path, json)
        end

      {:error, reason} ->
        Logger.warning("ResultStore: encode failed for #{path}: #{inspect(reason)}")
    end
  end

  defp resolve_runs_dir(opts) do
    case Keyword.get(opts, :runs_dir) do
      nil ->
        config = Application.get_env(:crucible, :orchestrator, [])
        repo_root = Keyword.get(config, :repo_root, File.cwd!())
        Path.join(repo_root, Keyword.get(config, :runs_dir, ".claude-flow/runs"))

      dir ->
        dir
    end
  end
end
