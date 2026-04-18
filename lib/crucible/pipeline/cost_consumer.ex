defmodule Crucible.Pipeline.CostConsumer do
  @moduledoc """
  GenStage consumer that tracks token usage and cost from Claude output.

  Parses output chunks for cost/token patterns, maintains running totals,
  and broadcasts updates via Phoenix.PubSub.
  """

  use GenStage
  require Logger

  @pubsub Crucible.PubSub

  defstruct [
    :session_id,
    :run_id,
    :phase_id,
    :budget_limit,
    input_tokens: 0,
    output_tokens: 0,
    total_cost: 0.0
  ]

  # --- Client API ---

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: opts[:name])
  end

  def get_totals(consumer) do
    GenStage.call(consumer, :get_totals)
  end

  @doc """
  Query current cost tracking state. Alias for `get_totals/1`.
  """
  def get_stats(consumer) do
    get_totals(consumer)
  end

  # --- GenStage callbacks ---

  @impl true
  def init(opts) do
    producer = opts[:producer] || raise "CostConsumer requires :producer"
    session_id = opts[:session_id] || opts[:session_name]
    run_id = opts[:run_id] || "unknown"
    phase_id = opts[:phase_id] || "p0"
    budget_limit = opts[:budget_limit] || 10.0

    state = %__MODULE__{
      session_id: session_id,
      run_id: run_id,
      phase_id: phase_id,
      budget_limit: budget_limit
    }

    {:consumer, state, subscribe_to: [{producer, max_demand: 50}]}
  end

  @impl true
  def handle_call(:get_totals, _from, state) do
    totals = %{
      input_tokens: state.input_tokens,
      output_tokens: state.output_tokens,
      total_cost: state.total_cost
    }

    {:reply, totals, [], state}
  end

  @impl true
  def handle_events(events, _from, state) do
    new_state = Enum.reduce(events, state, &process_event/2)
    {:noreply, [], new_state}
  end

  # --- Internal ---

  defp process_event(%{data: data}, state) when is_binary(data) and data != "" do
    cost_delta = extract_cost(data)
    {input_delta, output_delta} = extract_tokens(data)

    if cost_delta == 0.0 and input_delta == 0 and output_delta == 0 do
      state
    else
      new_state = %{
        state
        | input_tokens: state.input_tokens + input_delta,
          output_tokens: state.output_tokens + output_delta,
          total_cost: state.total_cost + cost_delta
      }

      broadcast_cost_update(new_state)
      maybe_signal_budget_exceeded(new_state)
      new_state
    end
  end

  defp process_event(_event, state), do: state

  defp extract_cost(data) do
    case Regex.run(~r/\$(\d+\.?\d*)/, data) do
      [_, amount] ->
        case Float.parse(amount) do
          {val, _} -> val
          :error -> 0.0
        end

      nil ->
        0.0
    end
  end

  defp extract_tokens(data) do
    input =
      case Regex.run(~r/(\d+)\s*input.tokens/i, data) do
        [_, n] -> String.to_integer(n)
        nil -> 0
      end

    output =
      case Regex.run(~r/(\d+)\s*output.tokens/i, data) do
        [_, n] -> String.to_integer(n)
        nil -> 0
      end

    {input, output}
  end

  defp broadcast_cost_update(state) do
    topic = if state.session_id, do: "pipeline:#{state.session_id}", else: "pipeline:costs"

    Phoenix.PubSub.broadcast(@pubsub, topic, %{
      event: :cost_update,
      run_id: state.run_id,
      phase_id: state.phase_id,
      input_tokens: state.input_tokens,
      output_tokens: state.output_tokens,
      total_cost: state.total_cost
    })
  end

  defp maybe_signal_budget_exceeded(%{total_cost: cost, budget_limit: limit} = state)
       when cost >= limit do
    Logger.warning(
      "CostConsumer: budget exceeded ($#{Float.round(cost, 2)} >= $#{Float.round(limit, 2)}) " <>
        "for run=#{state.run_id} phase=#{state.phase_id}"
    )

    payload = %{
      event: :budget_exceeded,
      run_id: state.run_id,
      phase_id: state.phase_id,
      total_cost: cost,
      budget_limit: limit
    }

    if state.session_id do
      Phoenix.PubSub.broadcast(@pubsub, "pipeline:#{state.session_id}", payload)
    end

    Phoenix.PubSub.broadcast(@pubsub, "pipeline:control", payload)
  end

  defp maybe_signal_budget_exceeded(_state), do: :ok
end
