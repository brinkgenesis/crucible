defmodule Crucible.Pipeline.DriftConsumerTest do
  use ExUnit.Case, async: true

  alias Crucible.Pipeline.{OutputProducer, DriftConsumer}

  setup do
    suffix = System.unique_integer([:positive])
    session_id = "drift-test-#{suffix}"
    producer_name = :"drift_test_producer_#{suffix}"
    consumer_name = :"drift_test_consumer_#{suffix}"

    _producer =
      start_supervised!(
        {OutputProducer,
         [
           name: producer_name,
           session_name: session_id,
           run_id: "run-d-#{suffix}",
           phase_id: "p1"
         ]}
      )

    _consumer =
      start_supervised!(
        {DriftConsumer,
         [
           name: consumer_name,
           producer: producer_name,
           session_id: session_id,
           run_id: "run-d-#{suffix}",
           phase_id: "p1",
           window_size: 10,
           repeat_threshold: 3
         ]}
      )

    Process.sleep(50)

    Phoenix.PubSub.subscribe(Crucible.PubSub, "pipeline:drift:#{session_id}")

    %{producer: producer_name, consumer: consumer_name, session_id: session_id}
  end

  test "starts and subscribes to producer", %{consumer: consumer} do
    assert Process.whereis(consumer) |> Process.alive?()
  end

  test "detects stuck loop when same output repeats N times", %{producer: producer} do
    for _ <- 1..3 do
      OutputProducer.push(producer, "I'm stuck in a loop")
      Process.sleep(20)
    end

    assert_receive %{event: :drift_alert, type: :stuck_loop}, 1000
    assert_receive %{event: :drift_termination, reason: "stuck_loop"}, 1000
  end

  test "does not trigger stuck loop below threshold", %{producer: producer} do
    OutputProducer.push(producer, "repeated line")
    Process.sleep(20)
    OutputProducer.push(producer, "repeated line")
    Process.sleep(20)
    OutputProducer.push(producer, "different line")

    refute_receive %{event: :drift_alert, type: :stuck_loop}, 300
  end

  test "detects repeated errors in sliding window", %{producer: producer} do
    # Use different error strings to avoid triggering stuck_loop (repeated_output?)
    # which takes precedence over error_pattern? in the cond
    OutputProducer.push(producer, "Error: first failure")
    Process.sleep(20)
    OutputProducer.push(producer, "Error: second failure")
    Process.sleep(20)
    OutputProducer.push(producer, "Error: third failure")

    assert_receive %{event: :drift_alert, type: :repeated_errors}, 3000
    assert_receive %{event: :drift_termination, reason: "repeated_errors"}, 3000
  end

  test "broadcasts error_detected for single errors", %{producer: producer} do
    OutputProducer.push(producer, "Error: one-off failure")

    assert_receive %{event: :drift_alert, type: :error_detected}, 1000
    refute_receive %{event: :drift_termination}, 200
  end

  test "sliding window evicts old entries", %{producer: producer, consumer: consumer} do
    for i <- 1..10 do
      OutputProducer.push(producer, "unique-#{i}")
      Process.sleep(10)
    end

    Process.sleep(100)
    state = DriftConsumer.get_state(consumer)
    assert state.window_length == 10

    OutputProducer.push(producer, "new-entry")
    Process.sleep(100)

    state = DriftConsumer.get_state(consumer)
    assert state.window_length == 10
  end

  test "tracks alert count", %{producer: producer, consumer: consumer} do
    for _ <- 1..3 do
      OutputProducer.push(producer, "Error: repeated failure")
      Process.sleep(20)
    end

    Process.sleep(200)
    state = DriftConsumer.get_state(consumer)
    assert state.alert_count >= 1
  end

  test "ignores empty events", %{producer: producer, consumer: consumer} do
    OutputProducer.push(producer, "")
    Process.sleep(100)

    state = DriftConsumer.get_state(consumer)
    assert state.window_length == 0
    assert state.alert_count == 0
  end

  test "matches various error patterns", %{producer: producer} do
    # Only test 2 patterns (below repeat_threshold of 3) to avoid triggering repeated_errors
    error_patterns = [
      "fatal: not a git repository",
      "panic: runtime error"
    ]

    for pattern <- error_patterns do
      OutputProducer.push(producer, pattern)
      assert_receive %{event: :drift_alert, type: :error_detected}, 3000
    end
  end
end
