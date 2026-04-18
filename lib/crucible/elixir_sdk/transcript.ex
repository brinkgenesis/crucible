defmodule Crucible.ElixirSdk.Transcript do
  @moduledoc """
  Serialised session transcript writer.

  Each `Crucible.ElixirSdk.Query` can opt in to persist its conversation
  as JSONL in `.crucible/sessions/<session_id>.jsonl`. Every entry is one
  of: `:message_start`, `:text_delta`, `:tool_call`, `:tool_result`,
  `:result`.

  Writes go through a single GenServer so entries are strictly ordered
  per session even when multiple queries share a session (rare, but
  possible with subagents).
  """

  use GenServer

  require Logger

  @type event :: map()

  # ── Public API ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Append an event to a session's transcript."
  @spec append(String.t(), event()) :: :ok
  def append(session_id, event) when is_binary(session_id) and is_map(event) do
    GenServer.cast(__MODULE__, {:append, session_id, event})
  end

  @doc "Path where transcripts are written."
  def base_dir do
    case Application.get_env(:crucible, :sessions_dir) do
      nil -> Path.join(File.cwd!(), ".crucible/sessions")
      p -> p
    end
  end

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    File.mkdir_p!(base_dir())
    {:ok, %{handles: %{}}}
  end

  @impl true
  def handle_cast({:append, session_id, event}, state) do
    state = ensure_handle(state, session_id)

    case Map.get(state.handles, session_id) do
      nil ->
        {:noreply, state}

      io ->
        line =
          event
          |> Map.put(:ts, DateTime.utc_now() |> DateTime.to_iso8601())
          |> Jason.encode!()

        IO.binwrite(io, line <> "\n")
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.handles, fn {_id, io} -> File.close(io) end)
  end

  defp ensure_handle(state, session_id) do
    case Map.get(state.handles, session_id) do
      nil ->
        path = Path.join(base_dir(), "#{session_id}.jsonl")

        case File.open(path, [:append, :utf8]) do
          {:ok, io} ->
            %{state | handles: Map.put(state.handles, session_id, io)}

          {:error, reason} ->
            Logger.warning("Transcript: failed to open #{path}: #{inspect(reason)}")
            state
        end

      _ ->
        state
    end
  end
end
