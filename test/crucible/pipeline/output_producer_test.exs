defmodule Crucible.Pipeline.OutputProducerTest do
  use ExUnit.Case, async: true

  alias Crucible.Claude.Session

  alias Crucible.Pipeline.{
    OutputProducer,
    CostConsumer,
    DriftConsumer,
    PipelineSupervisor
  }

  @pubsub Crucible.PubSub

  # --- Helper: simple GenStage consumer for testing ---

  defmodule TestConsumer do
    use GenStage

    def start_link(opts) do
      GenStage.start_link(__MODULE__, opts)
    end

    def init(opts) do
      producer = opts[:producer]
      test_pid = opts[:test_pid]
      {:consumer, %{test_pid: test_pid}, subscribe_to: [{producer, max_demand: 10}]}
    end

    def handle_events(events, _from, %{test_pid: pid} = state) do
      for event <- events, do: send(pid, {:consumed, event})
      {:noreply, [], state}
    end
  end

  # ============================================================
  # OutputProducer Tests
  # ============================================================

  describe "OutputProducer: initialization" do
    test "starts as a GenStage producer" do
      name = :"op_init_#{System.unique_integer([:positive])}"

      producer =
        start_supervised!(
          {OutputProducer, [name: name, session_name: "init-test", run_id: "r1", phase_id: "p0"]}
        )

      assert Process.alive?(producer)
    end

    test "uses default run_id and phase_id when not provided" do
      name = :"op_defaults_#{System.unique_integer([:positive])}"

      producer =
        start_supervised!({OutputProducer, [name: name, session_name: "defaults-test"]})

      assert Process.alive?(producer)
    end
  end

  describe "OutputProducer: push and demand" do
    setup do
      name = :"op_push_#{System.unique_integer([:positive])}"

      producer =
        start_supervised!(
          {OutputProducer,
           [name: name, session_name: "push-test", run_id: "run-1", phase_id: "p1"]}
        )

      {:ok, _consumer} = TestConsumer.start_link(producer: name, test_pid: self())
      Process.sleep(50)

      %{producer: producer, name: name}
    end

    test "dispatches events to a consumer via push/2", %{name: name} do
      OutputProducer.push(name, "hello world")

      assert_receive {:consumed, %{data: "hello world", chunk_index: 0, source: "push-test"}},
                     1000
    end

    test "increments chunk_index on each push", %{name: name} do
      OutputProducer.push(name, "first")
      OutputProducer.push(name, "second")
      OutputProducer.push(name, "third")

      assert_receive {:consumed, %{data: "first", chunk_index: 0}}, 1000
      assert_receive {:consumed, %{data: "second", chunk_index: 1}}, 1000
      assert_receive {:consumed, %{data: "third", chunk_index: 2}}, 1000
    end

    test "includes monotonic timestamp in events", %{name: name} do
      before = System.monotonic_time(:millisecond)
      OutputProducer.push(name, "data")

      assert_receive {:consumed, %{timestamp: ts}}, 1000
      assert ts >= before
    end

    test "handles demand callback without crashing", %{producer: producer} do
      assert Process.alive?(producer)
    end
  end

  describe "OutputProducer: notify/2 (alias for push/2)" do
    setup do
      name = :"op_notify_#{System.unique_integer([:positive])}"

      producer =
        start_supervised!(
          {OutputProducer,
           [name: name, session_name: "notify-test", run_id: "run-n", phase_id: "p1"]}
        )

      {:ok, _consumer} = TestConsumer.start_link(producer: name, test_pid: self())
      Process.sleep(50)

      %{producer: producer, name: name}
    end

    test "notify/2 dispatches events identically to push/2", %{name: name} do
      OutputProducer.notify(name, "via notify")

      assert_receive {:consumed, %{data: "via notify", chunk_index: 0, source: "notify-test"}},
                     1000
    end

    test "notify/2 and push/2 share chunk_index sequence", %{name: name} do
      OutputProducer.push(name, "first via push")
      OutputProducer.notify(name, "second via notify")
      OutputProducer.push(name, "third via push")

      assert_receive {:consumed, %{data: "first via push", chunk_index: 0}}, 1000
      assert_receive {:consumed, %{data: "second via notify", chunk_index: 1}}, 1000
      assert_receive {:consumed, %{data: "third via push", chunk_index: 2}}, 1000
    end
  end

  describe "OutputProducer: port and message handling" do
    test "handles unknown messages without crashing" do
      name = :"op_unknown_#{System.unique_integer([:positive])}"

      producer =
        start_supervised!(
          {OutputProducer,
           [name: name, session_name: "unknown-test", run_id: "r1", phase_id: "p0"]}
        )

      send(producer, :some_random_message)
      send(producer, {:unknown_message, "test"})
      Process.sleep(50)
      assert Process.alive?(producer)
    end
  end

  # ============================================================
  # CostConsumer Tests
  # ============================================================

  describe "CostConsumer: cost parsing" do
    setup do
      suffix = System.unique_integer([:positive])
      session_id = "cost-test-#{suffix}"
      producer_name = :"cc_prod_#{suffix}"
      consumer_name = :"cc_cons_#{suffix}"

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
      Phoenix.PubSub.subscribe(@pubsub, "pipeline:#{session_id}")

      %{producer: producer_name, consumer: consumer_name}
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

    test "get_stats/1 returns same data as get_totals/1", %{
      producer: producer,
      consumer: consumer
    } do
      OutputProducer.push(producer, "cost: $3.00, 200 input tokens, 100 output tokens")
      assert_receive %{event: :cost_update}, 1000

      totals = CostConsumer.get_totals(consumer)
      stats = CostConsumer.get_stats(consumer)

      assert totals == stats
      assert stats.total_cost == 3.0
      assert stats.input_tokens == 200
      assert stats.output_tokens == 100
    end

    test "broadcasts to session-scoped topic when session_id is set", %{producer: _producer} do
      # The CostConsumer in setup uses session_name which maps to session_id
      # It broadcasts to "pipeline:<session_id>" instead of "pipeline:costs"
      # We're already subscribed to "pipeline:costs" but let's verify session-scoped topic
      suffix = System.unique_integer([:positive])
      session_id = "scoped-session-#{suffix}"
      scoped_producer = :"scoped_prod_#{suffix}"
      scoped_consumer = :"scoped_cons_#{suffix}"

      start_supervised!(
        {OutputProducer,
         [name: scoped_producer, session_name: session_id, run_id: "run-sc", phase_id: "p1"]},
        id: :"scoped_prod_child_#{suffix}"
      )

      start_supervised!(
        {CostConsumer,
         [
           name: scoped_consumer,
           producer: scoped_producer,
           session_id: session_id,
           run_id: "run-sc",
           phase_id: "p1",
           budget_limit: 10.0
         ]},
        id: :"scoped_cons_child_#{suffix}"
      )

      Process.sleep(50)
      Phoenix.PubSub.subscribe(@pubsub, "pipeline:#{session_id}")

      OutputProducer.push(scoped_producer, "cost: $1.00")
      assert_receive %{event: :cost_update, total_cost: 1.0, run_id: "run-sc"}, 1000
    end
  end

  # ============================================================
  # DriftConsumer Tests
  # ============================================================

  describe "DriftConsumer: stuck loop detection" do
    setup do
      suffix = System.unique_integer([:positive])
      session_id = "drift-stuck-#{suffix}"
      producer_name = :"dc_stuck_prod_#{suffix}"
      consumer_name = :"dc_stuck_cons_#{suffix}"

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
      Phoenix.PubSub.subscribe(@pubsub, "pipeline:drift:#{session_id}")

      %{producer: producer_name, consumer: consumer_name}
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

    test "tracks alert count after stuck loop", %{producer: producer, consumer: consumer} do
      for _ <- 1..3 do
        OutputProducer.push(producer, "loop output")
        Process.sleep(20)
      end

      Process.sleep(200)
      state = DriftConsumer.get_state(consumer)
      assert state.alert_count >= 1
    end

    test "get_stats/1 returns same data as get_state/1", %{producer: producer, consumer: consumer} do
      OutputProducer.push(producer, "some output")
      Process.sleep(100)

      state = DriftConsumer.get_state(consumer)
      stats = DriftConsumer.get_stats(consumer)

      assert state == stats
      assert stats.window_length == 1
      assert stats.alert_count == 0
    end
  end

  describe "DriftConsumer: repeated error detection" do
    setup do
      suffix = System.unique_integer([:positive])
      session_id = "drift-err-#{suffix}"
      producer_name = :"dc_err_prod_#{suffix}"
      consumer_name = :"dc_err_cons_#{suffix}"

      _producer =
        start_supervised!(
          {OutputProducer,
           [
             name: producer_name,
             session_name: session_id,
             run_id: "run-e-#{suffix}",
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
             run_id: "run-e-#{suffix}",
             phase_id: "p1",
             window_size: 10,
             repeat_threshold: 3
           ]}
        )

      Process.sleep(50)
      Phoenix.PubSub.subscribe(@pubsub, "pipeline:drift:#{session_id}")

      %{producer: producer_name, consumer: consumer_name}
    end

    test "detects repeated errors in sliding window", %{producer: producer} do
      # Use different error strings to avoid triggering stuck_loop (repeated_output?)
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

  describe "DriftConsumer: off-topic detection" do
    setup do
      suffix = System.unique_integer([:positive])
      session_id = "drift-ot-#{suffix}"
      producer_name = :"dc_ot_prod_#{suffix}"
      consumer_name = :"dc_ot_cons_#{suffix}"

      _producer =
        start_supervised!(
          {OutputProducer,
           [
             name: producer_name,
             session_name: session_id,
             run_id: "run-ot-#{suffix}",
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
             run_id: "run-ot-#{suffix}",
             phase_id: "p1",
             window_size: 20,
             repeat_threshold: 3
           ]}
        )

      Process.sleep(50)
      Phoenix.PubSub.subscribe(@pubsub, "pipeline:drift:#{session_id}")

      %{producer: producer_name, consumer: consumer_name}
    end

    test "detects off-topic 'I can't' pattern", %{producer: producer} do
      OutputProducer.push(producer, "I can't do that for you")

      assert_receive %{event: :drift_alert, type: :off_topic_detected}, 1000
    end

    test "detects off-topic 'I'm unable' pattern", %{producer: producer} do
      OutputProducer.push(producer, "I'm unable to complete the task")

      assert_receive %{event: :drift_alert, type: :off_topic_detected}, 1000
    end

    test "detects off-topic 'as an AI' pattern", %{producer: producer} do
      OutputProducer.push(producer, "As an AI language model, I have limitations")

      assert_receive %{event: :drift_alert, type: :off_topic_detected}, 1000
    end

    test "detects off-topic 'I apologize' pattern", %{producer: producer} do
      OutputProducer.push(producer, "I apologize for the confusion")

      assert_receive %{event: :drift_alert, type: :off_topic_detected}, 1000
    end

    test "signals termination when off-topic count reaches threshold", %{producer: producer} do
      OutputProducer.push(producer, "I can't help with that")
      Process.sleep(30)
      OutputProducer.push(producer, "I'm unable to assist")
      Process.sleep(30)
      OutputProducer.push(producer, "I cannot do this task")
      Process.sleep(30)

      assert_receive %{event: :drift_alert, type: :off_topic}, 1000
      assert_receive %{event: :drift_termination, reason: "off_topic"}, 1000
    end

    test "tracks off_topic_count in state", %{producer: producer, consumer: consumer} do
      OutputProducer.push(producer, "I'm sorry, but I can't do that")
      Process.sleep(100)

      state = DriftConsumer.get_state(consumer)
      assert state.off_topic_count == 1
    end

    test "does not flag normal output as off-topic", %{producer: producer} do
      OutputProducer.push(producer, "Here is the implementation for the function")
      Process.sleep(100)

      refute_receive %{event: :drift_alert, type: :off_topic_detected}, 200
    end
  end

  describe "DriftConsumer: sliding window" do
    setup do
      suffix = System.unique_integer([:positive])
      session_id = "drift-win-#{suffix}"
      producer_name = :"dc_win_prod_#{suffix}"
      consumer_name = :"dc_win_cons_#{suffix}"

      _producer =
        start_supervised!(
          {OutputProducer,
           [
             name: producer_name,
             session_name: session_id,
             run_id: "run-w-#{suffix}",
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
             run_id: "run-w-#{suffix}",
             phase_id: "p1",
             window_size: 5,
             repeat_threshold: 3
           ]}
        )

      Process.sleep(50)

      %{producer: producer_name, consumer: consumer_name}
    end

    test "window does not exceed configured size", %{producer: producer, consumer: consumer} do
      for i <- 1..10 do
        OutputProducer.push(producer, "unique-#{i}")
        Process.sleep(10)
      end

      Process.sleep(100)
      state = DriftConsumer.get_state(consumer)
      assert state.window_length == 5
    end

    test "evicts old entries when window is full", %{producer: producer, consumer: consumer} do
      for i <- 1..5 do
        OutputProducer.push(producer, "line-#{i}")
        Process.sleep(10)
      end

      Process.sleep(50)
      state = DriftConsumer.get_state(consumer)
      assert state.window_length == 5

      OutputProducer.push(producer, "new-entry")
      Process.sleep(50)

      state = DriftConsumer.get_state(consumer)
      assert state.window_length == 5
    end

    test "ignores empty events", %{producer: producer, consumer: consumer} do
      OutputProducer.push(producer, "")
      Process.sleep(100)

      state = DriftConsumer.get_state(consumer)
      assert state.window_length == 0
      assert state.alert_count == 0
    end
  end

  describe "DriftConsumer: budget burn detection" do
    test "detects rapid cost acceleration via PubSub" do
      suffix = System.unique_integer([:positive])
      session_id = "drift-burn-#{suffix}"
      producer_name = :"dc_burn_prod_#{suffix}"
      consumer_name = :"dc_burn_cons_#{suffix}"

      _producer =
        start_supervised!(
          {OutputProducer,
           [
             name: producer_name,
             session_name: session_id,
             run_id: "run-b-#{suffix}",
             phase_id: "p1"
           ]}
        )

      consumer_pid =
        start_supervised!(
          {DriftConsumer,
           [
             name: consumer_name,
             producer: producer_name,
             session_id: session_id,
             run_id: "run-b-#{suffix}",
             phase_id: "p1",
             window_size: 10,
             repeat_threshold: 3
           ]}
        )

      Process.sleep(50)
      Phoenix.PubSub.subscribe(@pubsub, "pipeline:drift:#{session_id}")

      # Simulate accelerating cost updates directly to the consumer
      # c3=1.0, c2=2.0, c1=5.0 → delta1=3.0, delta2=1.0, 3.0 > 1.0*1.5 → burn!
      send(consumer_pid, %{event: :cost_update, total_cost: 1.0})
      Process.sleep(20)
      send(consumer_pid, %{event: :cost_update, total_cost: 2.0})
      Process.sleep(20)
      send(consumer_pid, %{event: :cost_update, total_cost: 5.0})
      Process.sleep(20)

      assert_receive %{event: :drift_alert, type: :budget_burn}, 1000
    end

    test "does not alert on steady cost growth" do
      suffix = System.unique_integer([:positive])
      session_id = "drift-steady-#{suffix}"
      producer_name = :"dc_steady_prod_#{suffix}"
      consumer_name = :"dc_steady_cons_#{suffix}"

      _producer =
        start_supervised!(
          {OutputProducer,
           [
             name: producer_name,
             session_name: session_id,
             run_id: "run-s-#{suffix}",
             phase_id: "p1"
           ]}
        )

      consumer_pid =
        start_supervised!(
          {DriftConsumer,
           [
             name: consumer_name,
             producer: producer_name,
             session_id: session_id,
             run_id: "run-s-#{suffix}",
             phase_id: "p1",
             window_size: 10,
             repeat_threshold: 3
           ]}
        )

      Process.sleep(50)
      Phoenix.PubSub.subscribe(@pubsub, "pipeline:drift:#{session_id}")

      # Steady growth: c3=1.0, c2=2.0, c1=3.0 → delta1=1.0, delta2=1.0, 1.0 > 1.5? No
      send(consumer_pid, %{event: :cost_update, total_cost: 1.0})
      Process.sleep(20)
      send(consumer_pid, %{event: :cost_update, total_cost: 2.0})
      Process.sleep(20)
      send(consumer_pid, %{event: :cost_update, total_cost: 3.0})
      Process.sleep(100)

      refute_receive %{event: :drift_alert, type: :budget_burn}, 200
    end
  end

  # ============================================================
  # PipelineSupervisor Tests
  # ============================================================

  describe "PipelineSupervisor: lifecycle" do
    setup do
      suffix = System.unique_integer([:positive])
      session = "sup-test-#{suffix}"
      %{session: session}
    end

    test "start_pipeline starts all pipeline components", %{session: session} do
      {:ok, sup_pid} =
        PipelineSupervisor.start_pipeline(
          session_name: session,
          run_id: "run-s",
          phase_id: "p1"
        )

      assert Process.alive?(sup_pid)

      producer = Process.whereis(PipelineSupervisor.producer_name(session))
      cost_consumer = Process.whereis(:"cost_consumer_#{session}")
      drift_consumer = Process.whereis(:"drift_consumer_#{session}")

      assert producer != nil
      assert cost_consumer != nil
      assert drift_consumer != nil
      assert Process.alive?(producer)
      assert Process.alive?(cost_consumer)
      assert Process.alive?(drift_consumer)

      PipelineSupervisor.stop_pipeline(session)
    end

    test "stop_pipeline cleanly shuts down", %{session: session} do
      {:ok, sup_pid} =
        PipelineSupervisor.start_pipeline(session_name: session, run_id: "run-s")

      assert Process.alive?(sup_pid)

      :ok = PipelineSupervisor.stop_pipeline(session)
      Process.sleep(50)

      refute Process.alive?(sup_pid)
      assert Process.whereis(PipelineSupervisor.producer_name(session)) == nil
    end

    test "stop_pipeline is idempotent for non-existent session" do
      assert :ok == PipelineSupervisor.stop_pipeline("nonexistent-session-999")
    end

    test "start_pipeline returns existing pid if already started", %{session: session} do
      {:ok, pid1} = PipelineSupervisor.start_pipeline(session_name: session)
      {:ok, pid2} = PipelineSupervisor.start_pipeline(session_name: session)

      assert pid1 == pid2

      PipelineSupervisor.stop_pipeline(session)
    end

    test "producer_name/1 returns expected atom", %{session: session} do
      assert PipelineSupervisor.producer_name(session) == :"producer_#{session}"
    end

    test "running?/1 returns true for active pipeline", %{session: session} do
      {:ok, _sup} = PipelineSupervisor.start_pipeline(session_name: session)
      assert PipelineSupervisor.running?(session)

      PipelineSupervisor.stop_pipeline(session)
      Process.sleep(50)
      refute PipelineSupervisor.running?(session)
    end

    test "lookup/1 returns pid for active pipeline", %{session: session} do
      assert PipelineSupervisor.lookup(session) == nil

      {:ok, sup_pid} = PipelineSupervisor.start_pipeline(session_name: session)
      assert PipelineSupervisor.lookup(session) == sup_pid

      PipelineSupervisor.stop_pipeline(session)
    end

    test "passes custom budget_limit through to CostConsumer", %{session: session} do
      Phoenix.PubSub.subscribe(@pubsub, "pipeline:#{session}")

      {:ok, _sup} =
        PipelineSupervisor.start_pipeline(
          session_name: session,
          run_id: "run-opts-#{session}",
          budget_limit: 0.01
        )

      Process.sleep(50)

      producer_name = PipelineSupervisor.producer_name(session)
      OutputProducer.push(producer_name, "cost: $1.00")

      assert_receive %{event: :budget_exceeded, budget_limit: 0.01}, 2000

      PipelineSupervisor.stop_pipeline(session)
    end
  end

  # ============================================================
  # Integration: Full Pipeline Flow
  # ============================================================

  describe "Integration: full pipeline flow" do
    test "data flows from producer through cost and drift consumers" do
      suffix = System.unique_integer([:positive])
      session = "int-test-#{suffix}"

      Phoenix.PubSub.subscribe(@pubsub, "pipeline:#{session}")
      Phoenix.PubSub.subscribe(@pubsub, "pipeline:drift:#{session}")

      {:ok, _sup} =
        PipelineSupervisor.start_pipeline(
          session_name: session,
          run_id: "run-int-#{suffix}",
          phase_id: "p1",
          repeat_threshold: 2
        )

      Process.sleep(200)
      producer_name = PipelineSupervisor.producer_name(session)

      OutputProducer.push(producer_name, "Total cost: $2.50, 100 input tokens")
      assert_receive %{event: :cost_update, total_cost: 2.5}, 3000

      OutputProducer.push(producer_name, "same output")
      Process.sleep(30)
      OutputProducer.push(producer_name, "same output")

      assert_receive %{event: :drift_alert, type: :stuck_loop}, 3000

      PipelineSupervisor.stop_pipeline(session)
    end

    test "pipeline handles mixed output types without crashing" do
      suffix = System.unique_integer([:positive])
      session = "int-mixed-#{suffix}"

      {:ok, _sup} =
        PipelineSupervisor.start_pipeline(
          session_name: session,
          run_id: "run-mix",
          phase_id: "p1"
        )

      Process.sleep(50)
      producer_name = PipelineSupervisor.producer_name(session)

      # Mix of different output types
      OutputProducer.push(producer_name, "normal output line")
      OutputProducer.push(producer_name, "cost: $0.50")
      OutputProducer.push(producer_name, "Error: something failed")
      OutputProducer.push(producer_name, "")
      OutputProducer.push(producer_name, "I can't help with that")
      OutputProducer.push(producer_name, "more normal output")

      Process.sleep(200)

      # Verify pipeline is still running
      assert PipelineSupervisor.running?(session)

      PipelineSupervisor.stop_pipeline(session)
    end
  end

  # ============================================================
  # Session pipeline topic tests
  # ============================================================

  describe "pipeline_topic/2" do
    test "builds scoped PubSub topic" do
      assert Session.pipeline_topic("run-123", "phase-0") == "pipeline:run-123:phase-0"
    end

    test "different run/phase combinations produce distinct topics" do
      t1 = Session.pipeline_topic("run-a", "p0")
      t2 = Session.pipeline_topic("run-a", "p1")
      t3 = Session.pipeline_topic("run-b", "p0")
      assert t1 != t2
      assert t1 != t3
    end
  end

  describe "drain_pipeline_signals/1" do
    test "returns :none when no signals pending" do
      assert Session.drain_pipeline_signals("test-session") == :none
    end

    test "handles terminate_phase signal" do
      send(self(), {:pipeline_terminate_phase, "run-1", "p0", "budget_exceeded"})
      assert {:terminate, "budget_exceeded"} = Session.drain_pipeline_signals("test-session")
    end

    test "drains only one signal per call" do
      send(self(), {:pipeline_terminate_phase, "run-1", "p0", "first"})
      send(self(), {:pipeline_terminate_phase, "run-1", "p0", "second"})

      assert {:terminate, "first"} = Session.drain_pipeline_signals("test-session")
      assert {:terminate, "second"} = Session.drain_pipeline_signals("test-session")
      assert :none = Session.drain_pipeline_signals("test-session")
    end
  end

  describe "PubSub pipeline feedback integration" do
    test "terminate_phase signal delivered via PubSub" do
      run_id = "run-pubsub-#{:rand.uniform(10000)}"
      phase_id = "p0"
      topic = Session.pipeline_topic(run_id, phase_id)

      Phoenix.PubSub.subscribe(@pubsub, topic)

      Phoenix.PubSub.broadcast(
        @pubsub,
        topic,
        {:pipeline_terminate_phase, run_id, phase_id, "cost_overrun"}
      )

      assert_receive {:pipeline_terminate_phase, ^run_id, ^phase_id, "cost_overrun"}
    end

    test "inject_prompt signal delivered via PubSub" do
      run_id = "run-inject-#{:rand.uniform(10000)}"
      phase_id = "p1"
      topic = Session.pipeline_topic(run_id, phase_id)

      Phoenix.PubSub.subscribe(@pubsub, topic)

      Phoenix.PubSub.broadcast(
        @pubsub,
        topic,
        {:pipeline_inject_prompt, run_id, phase_id, "Please reduce token usage"}
      )

      assert_receive {:pipeline_inject_prompt, ^run_id, ^phase_id, "Please reduce token usage"}
    end

    test "signals are scoped to their pipeline topic" do
      run_id_a = "run-scope-a-#{:rand.uniform(10000)}"
      run_id_b = "run-scope-b-#{:rand.uniform(10000)}"
      topic_a = Session.pipeline_topic(run_id_a, "p0")
      topic_b = Session.pipeline_topic(run_id_b, "p0")

      Phoenix.PubSub.subscribe(@pubsub, topic_a)

      Phoenix.PubSub.broadcast(
        @pubsub,
        topic_b,
        {:pipeline_terminate_phase, run_id_b, "p0", "other_session"}
      )

      refute_receive {:pipeline_terminate_phase, _, _, _}
    end
  end
end
