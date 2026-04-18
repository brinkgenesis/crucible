defmodule Crucible.ResultWriterTest do
  use ExUnit.Case

  alias Crucible.ResultWriter

  setup do
    # Read the runs_dir that ResultWriter GenServer computed at boot time.
    # Use the same logic as ResultWriter.init/1 but read config only once,
    # immune to concurrent tests that temporarily override :orchestrator config.
    runs_dir =
      case :sys.get_state(ResultWriter) do
        %{runs_dir: dir} -> dir
        state when is_map(state) -> Map.get(state, :runs_dir, ".claude-flow/runs")
        _ ->
          config = Application.get_env(:crucible, :orchestrator, [])
          repo_root = Keyword.get(config, :repo_root, File.cwd!())
          Path.join(repo_root, Keyword.get(config, :runs_dir, ".claude-flow/runs"))
      end

    File.mkdir_p!(runs_dir)
    {:ok, runs_dir: runs_dir}
  end

  defp write_manifest(runs_dir, run_id, manifest) do
    path = Path.join(runs_dir, "#{run_id}.manifest.json")
    File.write!(path, Jason.encode!(manifest))
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "write_result/2" do
    test "writes a result JSON file to disk", %{runs_dir: runs_dir} do
      run_id = "wr-test-#{:erlang.unique_integer([:positive])}"
      result = %{"status" => "done", "phases" => []}

      assert :ok = ResultWriter.write_result(run_id, result)

      path = Path.join(runs_dir, "#{run_id}.result.json")
      assert File.exists?(path)

      {:ok, decoded} = path |> File.read!() |> Jason.decode()
      assert decoded["status"] == "done"

      # Cleanup
      File.rm(path)
    end
  end

  describe "read_run/1" do
    test "reads an existing manifest", %{runs_dir: runs_dir} do
      run_id = "read-test-#{:erlang.unique_integer([:positive])}"
      manifest = %{"status" => "pending", "runId" => run_id}
      write_manifest(runs_dir, run_id, manifest)

      assert {:ok, read_manifest} = ResultWriter.read_run(run_id)
      assert read_manifest["status"] == "pending"
      assert read_manifest["runId"] == run_id
    end

    test "returns not_found for missing manifest" do
      assert {:error, :not_found} = ResultWriter.read_run("nonexistent-run-xyz")
    end
  end

  describe "transition_run_status/3" do
    test "valid transition pending -> running succeeds", %{runs_dir: runs_dir} do
      run_id = "trans-valid-#{:erlang.unique_integer([:positive])}"
      manifest = %{"status" => "pending", "runId" => run_id}
      write_manifest(runs_dir, run_id, manifest)

      assert {:ok, true} = ResultWriter.transition_run_status(run_id, "running", "key-1")

      # Verify the file was updated
      {:ok, updated} = ResultWriter.read_run(run_id)
      assert updated["status"] == "running"
      assert updated["lastTransitionKey"] == "key-1"
      assert updated["updatedAt"] != nil
    end

    test "valid transition running -> done succeeds", %{runs_dir: runs_dir} do
      run_id = "trans-done-#{:erlang.unique_integer([:positive])}"
      manifest = %{"status" => "running", "runId" => run_id}
      write_manifest(runs_dir, run_id, manifest)

      assert {:ok, true} = ResultWriter.transition_run_status(run_id, "done", "key-done")
    end

    test "valid transition running -> budget_paused succeeds", %{runs_dir: runs_dir} do
      run_id = "trans-budget-#{:erlang.unique_integer([:positive])}"
      manifest = %{"status" => "running", "runId" => run_id}
      write_manifest(runs_dir, run_id, manifest)

      assert {:ok, true} =
               ResultWriter.transition_run_status(run_id, "budget_paused", "key-budget")
    end

    test "valid transition budget_paused -> running succeeds", %{runs_dir: runs_dir} do
      run_id = "trans-resume-#{:erlang.unique_integer([:positive])}"
      manifest = %{"status" => "budget_paused", "runId" => run_id}
      write_manifest(runs_dir, run_id, manifest)

      assert {:ok, true} = ResultWriter.transition_run_status(run_id, "running", "key-resume")
    end

    test "valid transition failed -> running (retry) succeeds", %{runs_dir: runs_dir} do
      run_id = "trans-retry-#{:erlang.unique_integer([:positive])}"
      manifest = %{"status" => "failed", "runId" => run_id}
      write_manifest(runs_dir, run_id, manifest)

      assert {:ok, true} = ResultWriter.transition_run_status(run_id, "running", "key-retry")
    end

    test "invalid transition done -> pending returns error", %{runs_dir: runs_dir} do
      run_id = "trans-invalid-#{:erlang.unique_integer([:positive])}"
      manifest = %{"status" => "done", "runId" => run_id}
      write_manifest(runs_dir, run_id, manifest)

      assert {:error, {:invalid_transition, "done", "pending"}} =
               ResultWriter.transition_run_status(run_id, "pending", "key-bad")
    end

    test "invalid transition pending -> done returns error", %{runs_dir: runs_dir} do
      run_id = "trans-skip-#{:erlang.unique_integer([:positive])}"
      manifest = %{"status" => "pending", "runId" => run_id}
      write_manifest(runs_dir, run_id, manifest)

      assert {:error, {:invalid_transition, "pending", "done"}} =
               ResultWriter.transition_run_status(run_id, "done", "key-skip")
    end

    test "idempotent transition returns {:ok, false}", %{runs_dir: runs_dir} do
      run_id = "trans-idempotent-#{:erlang.unique_integer([:positive])}"
      manifest = %{"status" => "pending", "runId" => run_id}
      write_manifest(runs_dir, run_id, manifest)

      assert {:ok, true} = ResultWriter.transition_run_status(run_id, "running", "key-idem")
      # Same idempotency key — should skip
      assert {:ok, false} = ResultWriter.transition_run_status(run_id, "failed", "key-idem")

      # Verify status was NOT changed by the idempotent call
      {:ok, updated} = ResultWriter.read_run(run_id)
      assert updated["status"] == "running"
    end

    test "missing manifest returns not_found" do
      assert {:error, :not_found} =
               ResultWriter.transition_run_status("nonexistent-run", "running", "key-missing")
    end
  end

  describe "transition_run_status_with_trace/3" do
    test "broadcasts trace event on successful transition", %{runs_dir: runs_dir} do
      run_id = "trans-trace-#{:erlang.unique_integer([:positive])}"
      manifest = %{"status" => "pending", "runId" => run_id}
      write_manifest(runs_dir, run_id, manifest)

      # Subscribe to trace events
      Phoenix.PubSub.subscribe(Crucible.PubSub, "orchestrator:traces")

      assert {:ok, true} =
               ResultWriter.transition_run_status_with_trace(run_id, "running", "key-trace")

      assert_receive {:trace_event,
                      %{
                        type: "run_status_transition",
                        run_id: ^run_id,
                        status: "running"
                      }},
                     1000
    end

    test "does not broadcast on idempotent skip", %{runs_dir: runs_dir} do
      run_id = "trans-trace-idem-#{:erlang.unique_integer([:positive])}"
      manifest = %{"status" => "pending", "runId" => run_id}
      write_manifest(runs_dir, run_id, manifest)

      # First transition
      assert {:ok, true} =
               ResultWriter.transition_run_status_with_trace(run_id, "running", "key-ti")

      # Subscribe after the first broadcast to avoid stale messages
      Phoenix.PubSub.subscribe(Crucible.PubSub, "orchestrator:traces")

      # Same key — idempotent
      assert {:ok, false} =
               ResultWriter.transition_run_status_with_trace(run_id, "failed", "key-ti")

      refute_receive {:trace_event, %{run_id: ^run_id}}, 200
    end

    test "does not broadcast on invalid transition", %{runs_dir: runs_dir} do
      run_id = "trans-trace-bad-#{:erlang.unique_integer([:positive])}"
      manifest = %{"status" => "done", "runId" => run_id}
      write_manifest(runs_dir, run_id, manifest)

      Phoenix.PubSub.subscribe(Crucible.PubSub, "orchestrator:traces")

      assert {:error, {:invalid_transition, "done", "pending"}} =
               ResultWriter.transition_run_status_with_trace(run_id, "pending", "key-tb")

      refute_receive {:trace_event, %{run_id: ^run_id}}, 200
    end
  end

  describe "cleanup_residual_tasks/2" do
    test "returns 0 when no tasks directory exists" do
      assert 0 ==
               ResultWriter.cleanup_residual_tasks(
                 "nonexistent-team-#{System.unique_integer([:positive])}",
                 %{}
               )
    end
  end

  describe "cleanup_run_signals/2" do
    test "returns 0 when no signals directory exists" do
      assert 0 ==
               ResultWriter.cleanup_run_signals(
                 "/tmp/nonexistent-#{System.unique_integer([:positive])}",
                 %{"teamName" => "test"}
               )
    end

    test "returns 0 when team_name is nil" do
      assert 0 == ResultWriter.cleanup_run_signals("/tmp", %{})
    end

    test "returns 0 when team_name uses atom key but is nil" do
      assert 0 == ResultWriter.cleanup_run_signals("/tmp", %{team_name: nil})
    end
  end
end
