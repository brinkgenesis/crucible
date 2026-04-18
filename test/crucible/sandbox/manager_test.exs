defmodule Crucible.Sandbox.ManagerTest do
  use ExUnit.Case, async: false

  alias Crucible.Sandbox.Manager

  setup do
    # Use local mode for testing (no Docker required)
    prev = Application.get_env(:crucible, :sandbox)

    Application.put_env(:crucible, :sandbox,
      mode: :local,
      pool_size: 2,
      image: "node:22-alpine",
      policy_preset: :standard,
      router_host: "localhost:4800"
    )

    {:ok, pid} = Manager.start_link(name: :test_sandbox_manager)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      if prev, do: Application.put_env(:crucible, :sandbox, prev)
    end)

    %{pid: pid}
  end

  test "acquire returns a sandbox ID", %{pid: _pid} do
    assert {:ok, sandbox_id} = Manager.acquire("run-1", [workspace_path: "/tmp/test"], :test_sandbox_manager)
    assert is_binary(sandbox_id)
  end

  test "release succeeds for acquired sandbox", %{pid: _pid} do
    {:ok, sandbox_id} = Manager.acquire("run-2", [workspace_path: "/tmp/test"], :test_sandbox_manager)
    assert :ok = Manager.release(sandbox_id, :test_sandbox_manager)
  end

  test "release_for_run cleans up all sandboxes for a run", %{pid: _pid} do
    {:ok, _id1} = Manager.acquire("run-3", [workspace_path: "/tmp/test"], :test_sandbox_manager)
    {:ok, _id2} = Manager.acquire("run-3", [workspace_path: "/tmp/test"], :test_sandbox_manager)

    assert :ok = Manager.release_for_run("run-3", :test_sandbox_manager)

    status = Manager.status(:test_sandbox_manager)
    assert status.active_sandboxes == 0
  end

  test "status reports pool and active counts", %{pid: _pid} do
    status = Manager.status(:test_sandbox_manager)
    assert status.mode == :local
    assert is_integer(status.pool_available)
    assert status.active_sandboxes == 0
    assert status.active_runs == 0
  end

  test "acquire increments active count", %{pid: _pid} do
    {:ok, _id} = Manager.acquire("run-4", [workspace_path: "/tmp/test"], :test_sandbox_manager)
    status = Manager.status(:test_sandbox_manager)
    assert status.active_sandboxes == 1
    assert status.active_runs == 1
  end

  test "multiple acquires for same run tracked together", %{pid: _pid} do
    {:ok, _id1} = Manager.acquire("run-5", [workspace_path: "/tmp/test"], :test_sandbox_manager)
    {:ok, _id2} = Manager.acquire("run-5", [workspace_path: "/tmp/test"], :test_sandbox_manager)

    status = Manager.status(:test_sandbox_manager)
    assert status.active_sandboxes == 2
    assert status.active_runs == 1
  end
end
