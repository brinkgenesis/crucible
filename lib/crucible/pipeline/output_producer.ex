defmodule Crucible.Pipeline.OutputProducer do
  @moduledoc """
  GenStage producer that wraps Port/process output as a stream of events.

  Receives raw output messages (Port data, process messages) and dispatches
  them as GenStage events with metadata (timestamp, chunk index, source).
  """

  use GenStage
  require Logger

  defstruct [:source, :session_name, :run_id, :phase_id, chunk_index: 0, buffer: []]

  @type event :: %{
          data: binary(),
          timestamp: integer(),
          chunk_index: non_neg_integer(),
          source: term()
        }

  # --- Client API ---

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Manually push output data into the producer (for tmux capture or test injection).
  """
  def push(producer, data) when is_binary(data) do
    GenStage.cast(producer, {:push, data})
  end

  @doc """
  Push output data into the producer. Alias for `push/2` used by Session integration.
  """
  def notify(producer, data) when is_binary(data) do
    push(producer, data)
  end

  # --- GenStage callbacks ---

  @impl true
  def init(opts) do
    state = %__MODULE__{
      source: opts[:source],
      session_name: opts[:session_name],
      run_id: opts[:run_id] || "unknown",
      phase_id: opts[:phase_id] || "p0"
    }

    Logger.info("OutputProducer: started for session #{state.session_name}")
    {:producer, state, dispatcher: GenStage.BroadcastDispatcher}
  end

  @impl true
  def handle_cast({:push, data}, state) do
    event = build_event(data, state)
    new_state = %{state | chunk_index: state.chunk_index + 1}
    {:noreply, [event], new_state}
  end

  @impl true
  def handle_info({port, {:data, data}}, state) when is_port(port) do
    event = build_event(IO.iodata_to_binary(data), state)
    new_state = %{state | chunk_index: state.chunk_index + 1}
    {:noreply, [event], new_state}
  end

  def handle_info({port, :eof}, state) when is_port(port) do
    Logger.info("OutputProducer: port EOF for session #{state.session_name}")
    event = build_event("", %{state | source: :eof})
    {:noreply, [event], state}
  end

  def handle_info({:EXIT, port, reason}, state) when is_port(port) do
    Logger.info("OutputProducer: port exited (#{inspect(reason)}) for #{state.session_name}")
    {:noreply, [], state}
  end

  def handle_info(_msg, state) do
    {:noreply, [], state}
  end

  @impl true
  def handle_demand(_demand, state) do
    # We are a push-based producer — events dispatched when data arrives
    {:noreply, [], state}
  end

  # --- Internal ---

  defp build_event(data, state) do
    %{
      data: data,
      timestamp: System.monotonic_time(:millisecond),
      chunk_index: state.chunk_index,
      source: state.session_name || state.source
    }
  end
end
