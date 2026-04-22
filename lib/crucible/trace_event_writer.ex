defmodule Crucible.TraceEventWriter do
  @moduledoc """
  Serialized writer for trace event JSONL files and batch DB insertion.

  Receives trace events from SdkPort streaming and:
  1. Appends to per-run JSONL files (`.claude-flow/logs/traces/{runId}.jsonl`)
  2. Batch-inserts to `trace_events` Postgres table every flush interval

  Serialization through a single GenServer prevents file corruption.
  """

  use GenServer
  require Logger

  alias Crucible.Repo
  alias Crucible.Schema.TraceEvent

  @flush_interval 5_000
  @max_batch_size 100

  defstruct [:traces_dir, pending: [], flush_timer: nil]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Append a trace event to the run's JSONL file and queue for DB batch insert"
  @spec write(String.t(), map()) :: :ok
  def write(run_id, event) when is_binary(run_id) and is_map(event) do
    GenServer.cast(__MODULE__, {:write, run_id, event})
  end

  # ── Callbacks ────────────────────────────────────────────────

  @impl true
  def init(opts) do
    traces_dir = Keyword.fetch!(opts, :traces_dir)
    File.mkdir_p(traces_dir)
    {:ok, %__MODULE__{traces_dir: traces_dir}}
  end

  @impl true
  def handle_cast({:write, run_id, event}, state) do
    event_with_meta =
      event
      |> Map.put_new("timestamp", DateTime.utc_now() |> DateTime.to_iso8601())
      |> Map.put_new("runId", run_id)
      |> Map.put("writer", "elixir")

    # Append to JSONL file
    path = Path.join(state.traces_dir, "#{run_id}.jsonl")

    case Jason.encode(event_with_meta) do
      {:ok, json} ->
        File.write(path, json <> "\n", [:append])

      {:error, reason} ->
        Logger.warning("TraceEventWriter: encode failed: #{inspect(reason)}")
    end

    # Queue for DB batch
    pending = [event_with_meta | state.pending]

    if length(pending) >= @max_batch_size do
      flush_to_db(pending)
      {:noreply, %{state | pending: []}}
    else
      state = maybe_schedule_flush(state)
      {:noreply, %{state | pending: pending}}
    end
  end

  @impl true
  def handle_info(:flush, state) do
    if state.pending != [] do
      flush_to_db(state.pending)
    end

    {:noreply, %{state | pending: [], flush_timer: nil}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.pending != [] do
      flush_to_db(state.pending)
    end
  end

  # ── Internals ────────────────────────────────────────────────

  defp maybe_schedule_flush(%{flush_timer: nil} = state) do
    ref = Process.send_after(self(), :flush, @flush_interval)
    %{state | flush_timer: ref}
  end

  defp maybe_schedule_flush(state), do: state

  defp flush_to_db(events) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      events
      |> Enum.map(fn e ->
        ts =
          case DateTime.from_iso8601(e["timestamp"] || "") do
            {:ok, dt, _} -> DateTime.truncate(dt, :second)
            _ -> now
          end

        %{
          timestamp: ts,
          trace_id: e["traceId"] || "",
          run_id: e["runId"],
          phase_id: e["phaseId"],
          agent_id: e["agentId"],
          session_id: e["sessionId"],
          event_type: e["eventType"] || "unknown",
          tool: e["tool"],
          detail: truncate_detail(e["detail"]),
          metadata: e["metadata"] || %{},
          client_id: e["clientId"]
        }
      end)
      |> Enum.reject(fn e -> e.trace_id == "" end)

    if entries != [] do
      Repo.insert_all(TraceEvent, entries,
        on_conflict: :nothing,
        conflict_target: []
      )
    end
  rescue
    e ->
      Logger.warning(
        "TraceEventWriter: DB flush failed (#{length(events)} events): #{Exception.message(e)}"
      )
  end

  defp truncate_detail(nil), do: nil
  defp truncate_detail(s) when byte_size(s) > 500, do: String.slice(s, 0, 500)
  defp truncate_detail(s), do: s
end
