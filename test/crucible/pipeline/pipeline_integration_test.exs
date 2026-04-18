defmodule Crucible.Pipeline.PipelineIntegrationTest do
  @moduledoc """
  Integration tests verifying end-to-end pipeline behavior:
  producer → cost consumer + drift consumer, with PubSub feedback.
  """
  use ExUnit.Case, async: false

  alias Crucible.Pipeline.{
    OutputProducer,
    CostConsumer,
    DriftConsumer,
    PipelineSupervisor
  }

  @pubsub Crucible.PubSub

  describe "full pipeline: producer → consumers" do
    setup do
      suffix = System.unique_integer([:positive])
      session = "int-full-#{suffix}"

      Phoenix.PubSub.subscribe(@pubsub, "pipeline:#{session}")
      Phoenix.PubSub.subscribe(@pubsub, "pipeline:drift:#{session}")

      {:ok, _sup} =
        PipelineSupervisor.start_pipeline(
          session_name: session,
          run_id: "run-int-#{suffix}",
          phase_id: "p1",
          repeat_threshold: 3,
          budget_limit: 5.0
        )

      # Wait for GenStage subscriptions to complete
      Process.sleep(200)
      producer = PipelineSupervisor.producer_name(session)

      on_exit(fn ->
        try do
          PipelineSupervisor.stop_pipeline(session)
        catch
          :exit, _ -> :ok
        end
      end)

      %{session: session, producer: producer, suffix: suffix, run_id: "run-int-#{suffix}"}
    end

    test "cost data flows from producer to CostConsumer and broadcasts", %{producer: producer} do
      OutputProducer.push(producer, "Total cost: $2.50, 500 input tokens")
      assert_receive %{event: :cost_update, total_cost: 2.5, input_tokens: 500}, 3000
    end

    test "drift data flows from producer to DriftConsumer", %{producer: producer} do
      OutputProducer.push(producer, "Error: compilation failed")
      assert_receive %{event: :drift_alert, type: :error_detected}, 3000
    end

    test "repeated errors trigger termination signal", %{producer: producer} do
      # Use different error strings to avoid triggering stuck_loop first
      OutputProducer.push(producer, "Error: failure one")
      Process.sleep(30)
      OutputProducer.push(producer, "Error: failure two")
      Process.sleep(30)
      OutputProducer.push(producer, "Error: failure three")

      assert_receive %{event: :drift_termination, reason: "repeated_errors"}, 3000
    end

    test "budget exceeded triggers control signal", %{producer: producer} do
      OutputProducer.push(producer, "cost: $6.00")
      assert_receive %{event: :budget_exceeded, total_cost: 6.0, budget_limit: 5.0}, 3000
    end

    test "notify/2 works through the full pipeline", %{producer: producer} do
      OutputProducer.notify(producer, "cost: $1.25")
      assert_receive %{event: :cost_update, total_cost: 1.25}, 3000
    end

    test "get_stats/1 works for both consumers after pipeline processes data", %{
      session: session,
      producer: producer
    } do
      OutputProducer.push(producer, "cost: $1.00, 100 input tokens, 50 output tokens")
      # Wait for PubSub confirmation that CostConsumer processed the event
      assert_receive %{event: :cost_update, total_cost: 1.0}, 3000
      # Allow DriftConsumer to also finish processing (GenStage consumers run independently)
      Process.sleep(500)

      cost_stats = CostConsumer.get_stats(:"cost_consumer_#{session}")
      assert cost_stats.total_cost == 1.0
      assert cost_stats.input_tokens == 100

      drift_stats = DriftConsumer.get_stats(:"drift_consumer_#{session}")
      assert drift_stats.window_length == 1
      assert drift_stats.alert_count == 0
    end

    test "pipeline handles rapid mixed output without crashing", %{
      session: session,
      producer: producer
    } do
      outputs = [
        "normal output",
        "cost: $0.50",
        "Error: something failed",
        "",
        "I can't help with that",
        "more normal output",
        "cost: $0.25, 200 input tokens",
        "another line",
        "fatal: git error",
        "final output"
      ]

      for line <- outputs do
        OutputProducer.push(producer, line)
        Process.sleep(10)
      end

      # Wait for last cost event to confirm pipeline is processing
      assert_receive %{event: :cost_update, total_cost: 0.75}, 3000
      assert PipelineSupervisor.running?(session)

      cost_stats = CostConsumer.get_stats(:"cost_consumer_#{session}")
      assert cost_stats.total_cost == 0.75
      assert cost_stats.input_tokens == 200
    end
  end

  describe "pipeline lifecycle" do
    test "multiple pipelines run independently" do
      suffix = System.unique_integer([:positive])
      session_a = "multi-a-#{suffix}"
      session_b = "multi-b-#{suffix}"

      Phoenix.PubSub.subscribe(@pubsub, "pipeline:#{session_a}")
      Phoenix.PubSub.subscribe(@pubsub, "pipeline:#{session_b}")

      {:ok, _} = PipelineSupervisor.start_pipeline(session_name: session_a, run_id: "run-a")
      {:ok, _} = PipelineSupervisor.start_pipeline(session_name: session_b, run_id: "run-b")
      Process.sleep(200)

      OutputProducer.push(PipelineSupervisor.producer_name(session_a), "cost: $1.00")
      OutputProducer.push(PipelineSupervisor.producer_name(session_b), "cost: $2.00")

      assert_receive %{event: :cost_update, total_cost: 1.0, run_id: "run-a"}, 3000
      assert_receive %{event: :cost_update, total_cost: 2.0, run_id: "run-b"}, 3000

      stats_a = CostConsumer.get_stats(:"cost_consumer_#{session_a}")
      stats_b = CostConsumer.get_stats(:"cost_consumer_#{session_b}")
      assert stats_a.total_cost == 1.0
      assert stats_b.total_cost == 2.0

      PipelineSupervisor.stop_pipeline(session_a)
      PipelineSupervisor.stop_pipeline(session_b)
    end

    test "stopping one pipeline does not affect another" do
      suffix = System.unique_integer([:positive])
      session_a = "stop-a-#{suffix}"
      session_b = "stop-b-#{suffix}"

      {:ok, _} = PipelineSupervisor.start_pipeline(session_name: session_a, run_id: "run-sa")
      {:ok, _} = PipelineSupervisor.start_pipeline(session_name: session_b, run_id: "run-sb")
      Process.sleep(50)

      PipelineSupervisor.stop_pipeline(session_a)
      Process.sleep(50)

      refute PipelineSupervisor.running?(session_a)
      assert PipelineSupervisor.running?(session_b)

      PipelineSupervisor.stop_pipeline(session_b)
    end
  end
end
