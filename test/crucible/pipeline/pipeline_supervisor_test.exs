defmodule Crucible.Pipeline.PipelineSupervisorTest do
  use ExUnit.Case, async: true

  alias Crucible.Pipeline.{PipelineSupervisor, OutputProducer}
  @registry Crucible.RunRegistry

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

    # Verify all children are running
    producer = GenServer.whereis(PipelineSupervisor.producer_name(session))
    cost_consumer = GenServer.whereis(PipelineSupervisor.cost_consumer_name(session))
    drift_consumer = GenServer.whereis(PipelineSupervisor.drift_consumer_name(session))

    assert producer != nil
    assert cost_consumer != nil
    assert drift_consumer != nil
    assert Process.alive?(producer)
    assert Process.alive?(cost_consumer)
    assert Process.alive?(drift_consumer)

    # Cleanup
    PipelineSupervisor.stop_pipeline(session)
  end

  test "stop_pipeline cleanly shuts down", %{session: session} do
    {:ok, sup_pid} =
      PipelineSupervisor.start_pipeline(session_name: session, run_id: "run-s")

    assert Process.alive?(sup_pid)

    :ok = PipelineSupervisor.stop_pipeline(session)
    Process.sleep(50)

    refute Process.alive?(sup_pid)
    assert GenServer.whereis(PipelineSupervisor.producer_name(session)) == nil
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

  test "data flows through the full pipeline", %{session: session} do
    Phoenix.PubSub.subscribe(Crucible.PubSub, "pipeline:#{session}")

    {:ok, _sup} =
      PipelineSupervisor.start_pipeline(
        session_name: session,
        run_id: "run-flow-#{session}",
        phase_id: "p1"
      )

    Process.sleep(100)

    producer_name = PipelineSupervisor.producer_name(session)
    OutputProducer.push(producer_name, "Total cost: $2.50, 100 input tokens")

    assert_receive %{event: :cost_update, total_cost: 2.5}, 2000

    PipelineSupervisor.stop_pipeline(session)
  end

  test "producer_name/1 returns registry-backed name", %{session: session} do
    assert PipelineSupervisor.producer_name(session) ==
             {:via, Registry, {@registry, {:pipeline_component, :producer, session}}}
  end

  test "passes custom options through to children", %{session: session} do
    Phoenix.PubSub.subscribe(Crucible.PubSub, "pipeline:#{session}")

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
