defmodule Crucible.RegistryTest do
  use ExUnit.Case, async: true

  alias Crucible.Orchestrator

  describe "RunRegistry" do
    test "lookup_run returns :not_found for unregistered run" do
      assert :not_found = Orchestrator.lookup_run("nonexistent-run-#{:rand.uniform(10000)}")
    end

    test "lookup_run returns process info after registration" do
      run_id = "reg-test-#{:rand.uniform(10000)}"

      task =
        Task.async(fn ->
          Registry.register(Crucible.RunRegistry, run_id, %{
            workflow_type: "test-wf",
            started_at: System.monotonic_time(:millisecond)
          })

          # Keep process alive for lookup
          receive do
            :done -> :ok
          after
            5_000 -> :ok
          end
        end)

      # Give registration time to complete
      Process.sleep(50)

      assert {:ok, pid, meta} = Orchestrator.lookup_run(run_id)
      assert is_pid(pid)
      assert meta.workflow_type == "test-wf"

      send(task.pid, :done)
      Task.await(task)
    end

    test "lookup_run returns :not_found after process exits" do
      run_id = "reg-exit-#{:rand.uniform(10000)}"

      task =
        Task.async(fn ->
          Registry.register(Crucible.RunRegistry, run_id, %{workflow_type: "test"})
          :ok
        end)

      Task.await(task)

      # Process exited, Registry auto-cleans
      Process.sleep(50)
      assert :not_found = Orchestrator.lookup_run(run_id)
    end
  end

  describe "State struct" do
    test "State struct has circuit_breakers and completed fields" do
      state = Crucible.Orchestrator.State.new([])
      assert state.completed == %{}
      assert state.circuit_breakers == %{}
    end
  end
end
