defmodule Crucible.TelemetryTest do
  use ExUnit.Case, async: true

  describe "orchestrator telemetry events" do
    test "run start event is emittable" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:orchestrator, :run, :start]
        ])

      :telemetry.execute(
        [:orchestrator, :run, :start],
        %{system_time: System.system_time(:millisecond)},
        %{run_id: "test-run", workflow_type: "test-wf"}
      )

      assert_receive {[:orchestrator, :run, :start], ^ref, measurements, metadata}
      assert is_integer(measurements.system_time)
      assert metadata.run_id == "test-run"
      assert metadata.workflow_type == "test-wf"
    end

    test "run stop event is emittable" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:orchestrator, :run, :stop]
        ])

      :telemetry.execute(
        [:orchestrator, :run, :stop],
        %{duration: 5000},
        %{run_id: "test-run", workflow_type: "test-wf", status: :completed}
      )

      assert_receive {[:orchestrator, :run, :stop], ^ref, measurements, metadata}
      assert measurements.duration == 5000
      assert metadata.status == :completed
    end

    test "phase execute_start event is emittable" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:orchestrator, :phase, :execute_start]
        ])

      :telemetry.execute(
        [:orchestrator, :phase, :execute_start],
        %{system_time: System.system_time(:millisecond)},
        %{run_id: "test-run", phase_id: "p0", phase_type: :session}
      )

      assert_receive {[:orchestrator, :phase, :execute_start], ^ref, _, metadata}
      assert metadata.phase_type == :session
    end

    test "phase execute_stop event is emittable" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:orchestrator, :phase, :execute_stop]
        ])

      :telemetry.execute(
        [:orchestrator, :phase, :execute_stop],
        %{duration: 12_000},
        %{run_id: "test-run", phase_id: "p0", phase_type: :session, status: :completed}
      )

      assert_receive {[:orchestrator, :phase, :execute_stop], ^ref, measurements, metadata}
      assert measurements.duration == 12_000
      assert metadata.status == :completed
    end

    test "budget check event is emittable" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:orchestrator, :budget, :check]
        ])

      :telemetry.execute(
        [:orchestrator, :budget, :check],
        %{system_time: System.system_time(:millisecond), spent: 45.0},
        %{run_id: "test-run", phase_id: "p0", tier: :daily, exceeded: true}
      )

      assert_receive {[:orchestrator, :budget, :check], ^ref, measurements, metadata}
      assert measurements.spent == 45.0
      assert metadata.exceeded == true
    end
  end

  describe "periodic measurements" do
    test "emit_orchestrator_gauges does not crash" do
      assert :ok = CrucibleWeb.Telemetry.emit_orchestrator_gauges()
    end
  end
end
