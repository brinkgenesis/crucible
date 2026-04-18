defmodule Crucible.LogBuffer do
  @moduledoc """
  In-memory ring buffer for Elixir application logs.
  Stores the last @max_entries structured log entries.
  Entries are pushed by LogBuffer.Handler (Erlang :logger handler).
  """
  use GenServer

  @max_entries 500

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    max = Keyword.get(opts, :max_entries, @max_entries)
    GenServer.start_link(__MODULE__, %{max: max}, name: name)
  end

  @doc "Push a log entry into the buffer."
  def push(entry, name \\ __MODULE__) do
    GenServer.cast(name, {:push, entry})
  end

  @doc "Returns the last N entries (oldest first)."
  def recent(n \\ 100, name \\ __MODULE__) do
    GenServer.call(name, {:recent, n})
  catch
    :exit, _ -> []
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(%{max: max}) do
    {:ok, %{queue: :queue.new(), count: 0, max: max}}
  end

  @impl true
  def handle_cast({:push, entry}, state) do
    queue = :queue.in(entry, state.queue)
    count = state.count + 1

    {queue, count} =
      if count > state.max do
        {{:value, _}, q} = :queue.out(queue)
        {q, count - 1}
      else
        {queue, count}
      end

    try do
      Crucible.Events.broadcast_log_entry(entry)
    catch
      _, _ -> :ok
    end

    {:noreply, %{state | queue: queue, count: count}}
  end

  @impl true
  def handle_call({:recent, n}, _from, state) do
    entries = :queue.to_list(state.queue) |> Enum.take(-n)
    {:reply, entries, state}
  end
end

defmodule Crucible.LogBuffer.Handler do
  @moduledoc """
  Erlang :logger handler that pushes structured entries to LogBuffer.
  Registered via `:logger.add_handler/3` in Application.start/2.
  """

  def log(%{level: level, msg: msg, meta: meta}, _config) do
    message =
      case msg do
        {:string, str} -> IO.iodata_to_binary(str)
        {:report, report} -> inspect(report)
        {fmt, args} -> :io_lib.format(fmt, args) |> IO.iodata_to_binary()
      end

    timestamp =
      case Map.get(meta, :time) do
        nil -> ""
        microseconds -> format_timestamp(microseconds)
      end

    mod = Map.get(meta, :mfa, nil)

    module_name =
      case mod do
        {m, _f, _a} -> Atom.to_string(m)
        _ -> nil
      end

    entry = %{
      timestamp: timestamp,
      level: level,
      message: message,
      module: module_name,
      run_id: Map.get(meta, :run_id),
      request_id: Map.get(meta, :request_id)
    }

    try do
      Crucible.LogBuffer.push(entry)
    catch
      _, _ -> :ok
    end
  end

  defp format_timestamp(microseconds) when is_integer(microseconds) do
    seconds = div(microseconds, 1_000_000)
    {{y, m, d}, {h, mi, s}} = :calendar.system_time_to_universal_time(seconds, :second)

    :io_lib.format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [y, m, d, h, mi, s])
    |> IO.iodata_to_binary()
  end

  defp format_timestamp(_), do: ""
end
