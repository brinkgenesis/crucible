defmodule Crucible.Pipeline.CostConsumerTest do
  use ExUnit.Case, async: true

  alias Crucible.Pipeline.{OutputProducer, CostConsumer}

  setup do
    suffix = System.unique_integer([:positive])
    session_id = "cost-test-#{suffix}"
    producer_name = :"cost_test_producer_#{suffix}"
    consumer_name = :"cost_test_consumer_#{suffix}"

    _producer =
      start_supervised!(
        {OutputProducer,
         [
           name: producer_name,
           session_name: session_id,
           run_id: "run-c-#{suffix}",
           phase_id: "p1"
         ]}
      )

    _consumer =
      start_supervised!(
        {CostConsumer,
         [
           name: consumer_name,
           producer: producer_name,
           session_id: session_id,
           run_id: "run-c-#{suffix}",
           phase_id: "p1",
           budget_limit: 5.0
         ]}
      )

    Process.sleep(50)

    Phoenix.PubSub.subscribe(Crucible.PubSub, "pipeline:#{session_id}")

    %{producer: producer_name, consumer: consumer_name, session_id: session_id}
  end

  test "starts and subscribes to producer", %{consumer: consumer} do
    assert Process.whereis(consumer) |> Process.alive?()
  end

  test "parses cost from output and broadcasts update", %{producer: producer} do
    OutputProducer.push(producer, "Total cost: $1.50")

    assert_receive %{event: :cost_update, total_cost: 1.5}, 1000
  end

  test "parses token counts from output", %{producer: producer, consumer: consumer} do
    OutputProducer.push(producer, "Used 1000 input tokens and 500 output tokens, cost $0.02")

    assert_receive %{event: :cost_update, input_tokens: 1000, output_tokens: 500}, 1000

    totals = CostConsumer.get_totals(consumer)
    assert totals.input_tokens == 1000
    assert totals.output_tokens == 500
  end

  test "accumulates costs across multiple events", %{producer: producer, consumer: consumer} do
    OutputProducer.push(producer, "cost: $1.00")
    assert_receive %{event: :cost_update, total_cost: 1.0}, 1000

    OutputProducer.push(producer, "cost: $2.50")
    assert_receive %{event: :cost_update, total_cost: 3.5}, 1000

    totals = CostConsumer.get_totals(consumer)
    assert totals.total_cost == 3.5
  end

  test "ignores events with no cost or token data", %{producer: producer, consumer: consumer} do
    OutputProducer.push(producer, "just some regular output text")
    Process.sleep(100)

    totals = CostConsumer.get_totals(consumer)
    assert totals.total_cost == 0.0
    assert totals.input_tokens == 0
  end

  test "signals budget exceeded when cost exceeds limit", %{producer: producer} do
    OutputProducer.push(producer, "big bill: $6.00")

    assert_receive %{event: :budget_exceeded, total_cost: 6.0, budget_limit: 5.0}, 1000
  end

  test "does not signal budget exceeded under limit", %{producer: producer} do
    OutputProducer.push(producer, "small bill: $1.00")
    assert_receive %{event: :cost_update}, 1000

    refute_receive %{event: :budget_exceeded}, 200
  end

  test "ignores empty data events", %{producer: producer, consumer: consumer} do
    OutputProducer.push(producer, "")
    Process.sleep(100)

    totals = CostConsumer.get_totals(consumer)
    assert totals.total_cost == 0.0
  end
end
