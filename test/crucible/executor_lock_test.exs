defmodule Crucible.ExecutorLockTest do
  use ExUnit.Case, async: true

  alias Crucible.ExecutorLock

  @tmp_dir System.tmp_dir!()

  setup do
    test_dir = Path.join(@tmp_dir, "executor_lock_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(test_dir)
    on_exit(fn -> File.rm_rf!(test_dir) end)
    {:ok, dir: test_dir}
  end

  describe "acquire/1" do
    test "acquires lock when none exists", %{dir: dir} do
      assert {:ok, data} = ExecutorLock.acquire(dir)
      assert is_integer(data.pid)
      assert data.fence_id == 1
    end

    test "increments fence counter on successive acquires", %{dir: dir} do
      {:ok, d1} = ExecutorLock.acquire(dir)
      ExecutorLock.release(dir)
      {:ok, d2} = ExecutorLock.acquire(dir)
      assert d2.fence_id == d1.fence_id + 1
    end

    test "returns :locked when lock is held by alive process", %{dir: dir} do
      {:ok, _} = ExecutorLock.acquire(dir)
      assert {:error, :locked} = ExecutorLock.acquire(dir)
    end
  end

  describe "release/1" do
    test "releases lock owned by this process", %{dir: dir} do
      {:ok, _} = ExecutorLock.acquire(dir)
      assert :ok = ExecutorLock.release(dir)
      # Can re-acquire after release
      assert {:ok, _} = ExecutorLock.acquire(dir)
    end

    test "no-op when no lock exists", %{dir: dir} do
      assert :ok = ExecutorLock.release(dir)
    end
  end

  describe "heartbeat/1" do
    test "refreshes heartbeat timestamp", %{dir: dir} do
      {:ok, _} = ExecutorLock.acquire(dir)
      Process.sleep(10)
      assert :ok = ExecutorLock.heartbeat(dir)

      lock_path = Path.join([dir, ".claude-flow", "executor.lock"])
      {:ok, data} = ExecutorLock.read_lock(lock_path)
      assert data.heartbeat_at >= data.started_at
    end

    test "returns error when not owner", %{dir: dir} do
      assert {:error, :not_owner} = ExecutorLock.heartbeat(dir)
    end
  end

  describe "pid_alive?/1" do
    test "returns true for current process PID" do
      pid = System.pid() |> String.trim() |> String.to_integer()
      assert ExecutorLock.pid_alive?(pid) == true
    end

    test "returns false for non-existent PID" do
      assert ExecutorLock.pid_alive?(999_999_999) == false
    end
  end
end
