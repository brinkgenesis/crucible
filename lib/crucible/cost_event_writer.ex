defmodule Crucible.CostEventWriter do
  @moduledoc """
  Serialized writer for cost-events.jsonl.

  Receives cost events from SdkPort (via stdout streaming) and appends them
  atomically. Serialization through a single GenServer prevents file corruption
  from concurrent phase executions. Handles log rotation at 10MB.
  """

  use GenServer
  require Logger

  @max_file_bytes 10_485_760
  @max_rotations 3

  defstruct [:file_path, write_count: 0]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Append a cost event map to cost-events.jsonl"
  @spec write(map()) :: :ok
  def write(event) when is_map(event) do
    GenServer.cast(__MODULE__, {:write, event})
  end

  # ── Callbacks ────────────────────────────────────────────────

  @impl true
  def init(opts) do
    file_path = Keyword.fetch!(opts, :file_path)
    {:ok, %__MODULE__{file_path: file_path}}
  end

  @impl true
  def handle_cast({:write, event}, state) do
    event_with_meta =
      event
      |> Map.put_new("timestamp", DateTime.utc_now() |> DateTime.to_iso8601())
      |> Map.put("writer", "elixir")

    case Jason.encode(event_with_meta) do
      {:ok, json} ->
        maybe_rotate(state.file_path)
        File.write(state.file_path, json <> "\n", [:append])
        {:noreply, %{state | write_count: state.write_count + 1}}

      {:error, reason} ->
        Logger.warning("CostEventWriter: failed to encode event: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # ── Log rotation ─────────────────────────────────────────────

  defp maybe_rotate(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size >= @max_file_bytes ->
        rotate(path)

      _ ->
        :ok
    end
  end

  defp rotate(path) do
    # Shift .3 → delete, .2 → .3, .1 → .2, current → .1
    for i <- @max_rotations..2//-1 do
      src = "#{path}.#{i - 1}"
      dst = "#{path}.#{i}"

      if File.exists?(src) do
        File.rename(src, dst)
      end
    end

    if File.exists?(path) do
      File.rename(path, "#{path}.1")
    end
  rescue
    e -> Logger.warning("CostEventWriter: rotation failed: #{Exception.message(e)}")
  end
end
