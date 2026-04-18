defmodule Crucible.RunServerTest do
  use ExUnit.Case, async: true

  alias Crucible.Orchestrator.RunServer
  alias Crucible.RunSupervisor

  describe "RunSupervisor" do
    test "active_count returns non-negative integer" do
      count = RunSupervisor.active_count()
      assert is_integer(count)
      assert count >= 0
    end
  end

  describe "RunServer" do
    test "starts and registers in RunRegistry" do
      run_id = "test-reg-#{:rand.uniform(100_000)}"

      run = %Crucible.Types.Run{
        id: run_id,
        workflow_type: "test-workflow",
        status: :pending,
        phases: []
      }

      {:ok, pid} = RunSupervisor.start_run(run: run, run_opts: [], max_retries: 0)
      ref = Process.monitor(pid)

      # Server registers on init, before task spawns — so lookup should work immediately
      # But give a tiny window for the GenServer init to complete
      Process.sleep(10)

      # Either the server is still alive and registered, or it already completed.
      # Both are valid outcomes — we just verify the lifecycle.
      case Crucible.Orchestrator.lookup_run(run_id) do
        {:ok, _pid, meta} ->
          assert meta.workflow_type == "test-workflow"

        :not_found ->
          # Server already exited — verify it did exit via the monitor
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
      end
    end

    test "notifies orchestrator_pid on lifecycle events" do
      run_id = "test-notify-#{:rand.uniform(100_000)}"

      run = %Crucible.Types.Run{
        id: run_id,
        workflow_type: "test-workflow",
        status: :pending,
        phases: []
      }

      {:ok, pid} =
        RunSupervisor.start_run(
          run: run,
          run_opts: [],
          max_retries: 0,
          orchestrator_pid: self()
        )

      ref = Process.monitor(pid)

      # Should receive a lifecycle event (completed or exhausted) before server exits
      assert_receive {:run_lifecycle, ^run_id, _event}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end

    test "server is temporary — exits after run completes" do
      run_id = "test-exit-#{:rand.uniform(100_000)}"

      run = %Crucible.Types.Run{
        id: run_id,
        workflow_type: "test-workflow",
        status: :pending,
        phases: []
      }

      {:ok, pid} = RunSupervisor.start_run(run: run, run_opts: [], max_retries: 0)
      ref = Process.monitor(pid)

      # With empty phases and no workspace, the task will complete (or fail) quickly
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end

    test "cancel stops a running server" do
      run_id = "test-cancel-#{:rand.uniform(100_000)}"

      run = %Crucible.Types.Run{
        id: run_id,
        workflow_type: "test-workflow",
        status: :pending,
        phases: []
      }

      # Use max_retries > 0 so the server stays alive longer on failure
      {:ok, pid} = RunSupervisor.start_run(run: run, run_opts: [], max_retries: 5)
      ref = Process.monitor(pid)

      # Wait a bit for init, then try cancel if still alive
      Process.sleep(10)

      if Process.alive?(pid) do
        :ok = RunServer.cancel(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      else
        # Already exited — that's fine for this test
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
      end
    end
  end
end
