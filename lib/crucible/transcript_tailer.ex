defmodule Crucible.TranscriptTailer do
  @moduledoc """
  Tails Claude session transcript JSONL files incrementally.
  Broadcasts new tool_use events via PubSub for real-time UI streaming.

  Usage:
    TranscriptTailer.watch(session_id)   # start tailing a session
    TranscriptTailer.unwatch(session_id)  # stop tailing
    TranscriptTailer.events(session_id)   # get buffered events
    TranscriptTailer.watching()           # list watched sessions

  Subscribe to PubSub topic "session_events:{session_id}" to receive:
    {:new_tool_events, session_id, [%{tool: ..., timestamp: ..., detail: ...}]}
  """

  use GenServer
  require Logger

  @tick_ms 2_000
  @call_timeout 10_000
  @max_events_per_session 200
  @projects_dir Path.expand("~/.claude/projects")

  defstruct sessions: %{}
  # sessions: %{session_id => %{path: str, position: int, events: [map]}}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Start tailing a session transcript."
  def watch(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:watch, session_id}, @call_timeout)
  end

  @doc "Stop tailing a session."
  def unwatch(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:unwatch, session_id}, @call_timeout)
  end

  @doc "Get buffered events for a session (newest first)."
  @spec events(String.t(), non_neg_integer()) :: [map()]
  def events(session_id, limit \\ 100) do
    GenServer.call(__MODULE__, {:events, session_id, limit}, @call_timeout)
  catch
    :exit, _ -> []
  end

  @doc "List currently watched session IDs."
  def watching do
    GenServer.call(__MODULE__, :watching, @call_timeout)
  catch
    :exit, _ -> []
  end

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:watch, session_id}, _from, state) do
    if Map.has_key?(state.sessions, session_id) do
      {:reply, :already_watching, state}
    else
      case find_transcript(session_id) do
        nil ->
          Logger.warning("TranscriptTailer: no transcript found for #{session_id}")
          {:reply, {:error, :not_found}, state}

        path ->
          # Pre-load recent events from the file, then tail from EOF for new ones
          size = file_size(path)
          historical = load_recent_events(path, @max_events_per_session)
          entry = %{path: path, position: size, events: historical}
          sessions = Map.put(state.sessions, session_id, entry)
          Logger.info("TranscriptTailer: watching #{session_id} (#{length(historical)} historical events, position #{size})")
          {:reply, :ok, %{state | sessions: sessions}}
      end
    end
  end

  def handle_call({:unwatch, session_id}, _from, state) do
    sessions = Map.delete(state.sessions, session_id)
    {:reply, :ok, %{state | sessions: sessions}}
  end

  def handle_call({:events, session_id, limit}, _from, state) do
    events =
      case Map.get(state.sessions, session_id) do
        nil -> []
        entry -> Enum.take(entry.events, limit)
      end

    {:reply, events, state}
  end

  def handle_call(:watching, _from, state) do
    {:reply, Map.keys(state.sessions), state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = tail_all(state)
    schedule_tick()
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Tailing
  # ---------------------------------------------------------------------------

  defp tail_all(state) do
    sessions =
      state.sessions
      |> Enum.map(fn {session_id, entry} ->
        {session_id, tail_session(session_id, entry)}
      end)
      |> Enum.reject(fn {_id, result} -> result == :unwatch end)
      |> Map.new()

    %{state | sessions: sessions}
  end

  defp tail_session(session_id, entry) do
    # Check file still exists
    unless File.exists?(entry.path) do
      Logger.warning("TranscriptTailer: #{entry.path} deleted, marking for unwatch")
      throw({:unwatch, session_id})
    end

    current_size = file_size(entry.path)

    cond do
      # File was truncated/rotated — reset and re-read
      current_size < entry.position ->
        Logger.warning("TranscriptTailer: file truncated for #{session_id}, re-reading")
        historical = load_recent_events(entry.path, @max_events_per_session)
        %{entry | position: current_size, events: historical}

      # No new data
      current_size == entry.position ->
        entry

      # New data available — tail it
      true ->
        new_lines = read_from(entry.path, entry.position)
        new_events = extract_tool_events(new_lines)

        if new_events != [] do
          Phoenix.PubSub.broadcast(
            Crucible.PubSub,
            "session_events:#{session_id}",
            {:new_tool_events, session_id, new_events}
          )
        end

        all_events = new_events ++ entry.events
        capped = Enum.take(all_events, @max_events_per_session)

        %{entry | position: current_size, events: capped}
    end
  rescue
    e ->
      Logger.warning("TranscriptTailer: error tailing #{session_id}: #{inspect(e)}")
      entry
  catch
    {:unwatch, _sid} -> :unwatch
  end

  defp read_from(path, position) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        :file.position(device, position)
        data = IO.read(device, :eof)
        File.close(device)

        case data do
          :eof -> []
          {:error, _} -> []
          bin when is_binary(bin) -> String.split(bin, "\n", trim: true)
        end

      _ ->
        []
    end
  end

  defp extract_tool_events(lines) do
    lines
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"type" => "assistant", "message" => %{"content" => content}} = data}
            when is_list(content) ->
          ts = data["timestamp"] || ""

          content
          |> Enum.filter(&match?(%{"type" => "tool_use"}, &1))
          |> Enum.map(fn tool ->
            %{
              "tool" => tool["name"],
              "timestamp" => ts,
              "detail" => truncate_detail(tool["input"])
            }
          end)

        _ ->
          []
      end
    end)
    |> Enum.reverse()
  end

  # Load recent tool events from a full file read (used once on watch)
  defp load_recent_events(path, limit) do
    path
    |> File.stream!()
    |> Enum.reduce([], fn line, acc ->
      case Jason.decode(String.trim(line)) do
        {:ok, %{"type" => "assistant", "message" => %{"content" => content}} = data}
            when is_list(content) ->
          ts = data["timestamp"] || ""

          tools =
            content
            |> Enum.filter(&match?(%{"type" => "tool_use"}, &1))
            |> Enum.map(fn tool ->
              %{
                "tool" => tool["name"],
                "timestamp" => ts,
                "detail" => truncate_detail(tool["input"])
              }
            end)

          acc ++ tools

        _ ->
          acc
      end
    end)
    |> Enum.take(-limit)
    |> Enum.reverse()
  rescue
    e ->
      Logger.warning("TranscriptTailer: failed to load historical events: #{inspect(e)}")
      []
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp find_transcript(session_id) do
    if File.dir?(@projects_dir) do
      @projects_dir
      |> File.ls!()
      |> Enum.find_value(fn dir ->
        path = Path.join([@projects_dir, dir, "#{session_id}.jsonl"])
        if File.exists?(path), do: path
      end)
    end
  rescue
    _ -> nil
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp truncate_detail(nil), do: nil

  defp truncate_detail(input) when is_map(input) do
    cond do
      Map.has_key?(input, "command") -> String.slice(to_string(input["command"]), 0, 80)
      Map.has_key?(input, "file_path") -> input["file_path"]
      Map.has_key?(input, "pattern") -> "#{input["pattern"]}"
      Map.has_key?(input, "query") -> String.slice(to_string(input["query"]), 0, 80)
      Map.has_key?(input, "prompt") -> String.slice(to_string(input["prompt"]), 0, 60)
      Map.has_key?(input, "description") -> String.slice(to_string(input["description"]), 0, 80)
      Map.has_key?(input, "content") -> String.slice(to_string(input["content"]), 0, 60)
      true -> nil
    end
  end

  defp truncate_detail(_), do: nil

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)
end
