defmodule Crucible.Pipeline.DriftConsumer do
  @moduledoc """
  GenStage consumer that detects quality drift in Claude output.

  Monitors for repeated errors, stuck loops (same output N times),
  off-topic patterns, and budget burn acceleration.
  Broadcasts alerts via Phoenix.PubSub.
  """

  use GenStage
  require Logger

  @pubsub Crucible.PubSub

  @default_window_size 20
  @default_repeat_threshold 3
  @default_burn_rate_limit 1.5

  @off_topic_patterns [
    ~r/I can't/i,
    ~r/I'm unable/i,
    ~r/I cannot/i,
    ~r/I apologize/i,
    ~r/I'm sorry, but/i,
    ~r/as an AI/i,
    ~r/I don't have the ability/i
  ]

  defstruct [
    :run_id,
    :phase_id,
    :session_id,
    :window_size,
    :repeat_threshold,
    :burn_rate_limit,
    window: :queue.new(),
    window_length: 0,
    alert_count: 0,
    cost_history: [],
    off_topic_count: 0,
    error_freq: %{},
    patterns_detected: []
  ]

  # --- Client API ---

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: opts[:name])
  end

  def get_state(consumer) do
    GenStage.call(consumer, :get_state)
  end

  @doc "Alias for `get_state/1` — consistent API with CostConsumer."
  def get_stats(consumer), do: get_state(consumer)

  # --- GenStage callbacks ---

  @impl true
  def init(opts) do
    producer = opts[:producer] || raise "DriftConsumer requires :producer"
    session_id = opts[:session_id] || opts[:run_id] || "unknown"

    state = %__MODULE__{
      run_id: opts[:run_id] || "unknown",
      phase_id: opts[:phase_id] || "p0",
      session_id: session_id,
      window_size: opts[:window_size] || @default_window_size,
      repeat_threshold: opts[:repeat_threshold] || @default_repeat_threshold,
      burn_rate_limit: opts[:burn_rate_limit] || @default_burn_rate_limit
    }

    Phoenix.PubSub.subscribe(@pubsub, "pipeline:#{session_id}")

    {:consumer, state, subscribe_to: [{producer, max_demand: 50}]}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    info = %{
      window_length: state.window_length,
      alert_count: state.alert_count,
      off_topic_count: state.off_topic_count,
      error_frequencies: state.error_freq,
      patterns_detected: state.patterns_detected
    }

    {:reply, info, [], state}
  end

  @impl true
  def handle_events(events, _from, state) do
    new_state = Enum.reduce(events, state, &process_event/2)
    {:noreply, [], new_state}
  end

  @impl true
  def handle_info(%{event: :cost_update, total_cost: cost}, state) do
    now = System.monotonic_time(:millisecond)
    cost_history = [{now, cost} | state.cost_history] |> Enum.take(10)
    new_state = %{state | cost_history: cost_history}

    if budget_burn?(cost_history, state.burn_rate_limit) do
      new_state = record_pattern(new_state, :budget_burn)
      broadcast_drift(new_state, :budget_burn, "Rapid cost acceleration detected")
      {:noreply, [], %{new_state | alert_count: new_state.alert_count + 1}}
    else
      {:noreply, [], new_state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, [], state}
  end

  # --- Internal ---

  defp process_event(%{data: data}, state) when is_binary(data) and data != "" do
    trimmed = String.trim(data)
    state = push_to_window(state, trimmed)

    cond do
      repeated_output?(state, trimmed) ->
        state = record_pattern(state, :stuck_loop)

        broadcast_drift(
          state,
          :stuck_loop,
          "Repeated output detected (#{state.repeat_threshold}x)"
        )

        signal_termination(state, "stuck_loop")
        %{state | alert_count: state.alert_count + 1}

      off_topic?(trimmed) ->
        new_count = state.off_topic_count + 1

        if new_count >= state.repeat_threshold do
          state = record_pattern(state, :off_topic)
          broadcast_drift(state, :off_topic, "#{new_count} off-topic outputs in window")
          signal_termination(state, "off_topic")
          %{state | alert_count: state.alert_count + 1, off_topic_count: new_count}
        else
          broadcast_drift(state, :off_topic_detected, "Off-topic pattern found")
          %{state | off_topic_count: new_count}
        end

      error_pattern?(trimmed) ->
        state = track_error(state, trimmed)
        error_count = count_errors_in_window(state)

        if error_count >= state.repeat_threshold do
          state = record_pattern(state, :repeated_errors)
          broadcast_drift(state, :repeated_errors, "#{error_count} errors in sliding window")
          signal_termination(state, "repeated_errors")
          %{state | alert_count: state.alert_count + 1}
        else
          broadcast_drift(state, :error_detected, "Error pattern found")
          state
        end

      true ->
        state
    end
  end

  defp process_event(_event, state), do: state

  defp push_to_window(state, item) do
    new_queue = :queue.in(item, state.window)
    new_length = state.window_length + 1

    if new_length > state.window_size do
      {_, trimmed_queue} = :queue.out(new_queue)
      %{state | window: trimmed_queue, window_length: state.window_size}
    else
      %{state | window: new_queue, window_length: new_length}
    end
  end

  defp repeated_output?(state, item) do
    items = :queue.to_list(state.window)
    count = Enum.count(items, &(&1 == item))
    count >= state.repeat_threshold
  end

  defp off_topic?(data) do
    Enum.any?(@off_topic_patterns, &Regex.match?(&1, data))
  end

  defp error_pattern?(data) do
    Regex.match?(~r/\*\*Error|error:|Error:|FAILED|fatal:|panic:/i, data)
  end

  defp count_errors_in_window(state) do
    state.window
    |> :queue.to_list()
    |> Enum.count(&error_pattern?/1)
  end

  defp track_error(state, message) do
    # Normalize error message for frequency tracking (first 80 chars)
    key = message |> String.slice(0, 80) |> String.downcase()
    freq = Map.update(state.error_freq, key, 1, &(&1 + 1))
    %{state | error_freq: freq}
  end

  defp record_pattern(state, pattern) do
    if pattern in state.patterns_detected do
      state
    else
      %{state | patterns_detected: [pattern | state.patterns_detected]}
    end
  end

  defp budget_burn?(cost_history, _limit) when length(cost_history) < 3, do: false

  defp budget_burn?(cost_history, limit) do
    [{_t1, c1}, {_t2, c2}, {_t3, c3} | _] = cost_history
    delta1 = c1 - c2
    delta2 = c2 - c3
    delta1 > 0 and delta2 > 0 and delta1 > delta2 * limit
  end

  defp broadcast_drift(state, type, message) do
    Logger.warning("DriftConsumer: #{type} — #{message} (run=#{state.run_id})")

    payload = %{
      event: :drift_alert,
      type: type,
      message: message,
      run_id: state.run_id,
      phase_id: state.phase_id
    }

    Phoenix.PubSub.broadcast(@pubsub, "pipeline:drift:#{state.session_id}", payload)
    Phoenix.PubSub.broadcast(@pubsub, "pipeline:drift", payload)
  end

  defp signal_termination(state, reason) do
    payload = %{
      event: :drift_termination,
      reason: reason,
      run_id: state.run_id,
      phase_id: state.phase_id
    }

    Phoenix.PubSub.broadcast(@pubsub, "pipeline:drift:#{state.session_id}", payload)
    Phoenix.PubSub.broadcast(@pubsub, "pipeline:control", payload)
  end
end
