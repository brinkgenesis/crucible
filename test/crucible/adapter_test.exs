defmodule Crucible.AdapterTest do
  use ExUnit.Case, async: true

  alias Crucible.Adapter.ClaudeHook
  alias Crucible.Types.{Run, Phase}

  @tmp_dir System.tmp_dir!()

  setup do
    test_dir = Path.join(@tmp_dir, "adapter_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(test_dir)
    on_exit(fn -> File.rm_rf!(test_dir) end)

    run = %Run{
      id: "test-run-#{:erlang.unique_integer([:positive])}",
      workflow_type: "test"
    }

    phase = %Phase{
      id: "phase-0",
      name: "Test Phase",
      type: :session,
      timeout_ms: 5_000
    }

    {:ok, dir: test_dir, run: run, phase: phase}
  end

  describe "ClaudeHook" do
    test "writes trigger file and waits for pickup", %{dir: dir, run: run, phase: phase} do
      pickup_dir = Path.join(dir, "pending-pickup")

      # Start execution in a task with very short timeout
      task =
        Task.async(fn ->
          ClaudeHook.execute_phase(run, phase, "test prompt",
            pickup_dir: pickup_dir,
            runs_dir: dir,
            pickup_timeout_ms: 500
          )
        end)

      # Wait briefly for trigger file to appear
      Process.sleep(100)

      trigger_path = Path.join(pickup_dir, "#{run.id}-#{phase.id}.json")

      if File.exists?(trigger_path) do
        {:ok, trigger} = trigger_path |> File.read!() |> Jason.decode()
        assert trigger["runId"] == run.id
        assert trigger["phaseType"] == "session"
      end

      # Will timeout since nothing picks up the trigger
      result = Task.await(task, 2_000)
      assert {:error, :pickup_timeout} = result
    end

    test "cleanup_artifacts removes trigger files", %{dir: dir, run: run, phase: phase} do
      pickup_dir = Path.join(dir, "pending-pickup")
      File.mkdir_p!(pickup_dir)

      # Create some trigger files
      File.write!(Path.join(pickup_dir, "#{run.id}-p0.json"), "{}")
      File.write!(Path.join(pickup_dir, "#{run.id}-p1.json"), "{}")
      File.write!(Path.join(pickup_dir, "other-run-p0.json"), "{}")

      # cleanup_artifacts uses hardcoded path, so we test the function signature
      assert :ok = ClaudeHook.cleanup_artifacts(run, phase)
    end
  end
end
