defmodule Crucible.DreamGateTest do
  use ExUnit.Case, async: true

  alias Crucible.DreamGate

  @moduletag :tmp_dir

  describe "read_state/1" do
    test "returns empty state when no file exists", %{tmp_dir: tmp_dir} do
      state = DreamGate.read_state(tmp_dir)
      assert state.last_consolidated_at == nil
      assert state.sessions_since_last == 0
      assert state.total_runs == 0
    end

    test "reads existing state file", %{tmp_dir: tmp_dir} do
      learning_dir = Path.join(tmp_dir, ".claude-flow/learning")
      File.mkdir_p!(learning_dir)

      state = %{
        "last_consolidated_at" => "2026-04-13T10:00:00Z",
        "sessions_since_last" => 5,
        "total_runs" => 3,
        "total_tokens_spent" => 10_000,
        "total_cost_usd" => 0.50
      }

      File.write!(Path.join(learning_dir, "dream-state.json"), Jason.encode!(state))

      result = DreamGate.read_state(tmp_dir)
      assert result.last_consolidated_at == "2026-04-13T10:00:00Z"
      assert result.sessions_since_last == 5
      assert result.total_runs == 3
    end
  end

  describe "record_session_start/1" do
    test "increments session counter", %{tmp_dir: tmp_dir} do
      DreamGate.record_session_start(tmp_dir)
      assert DreamGate.read_state(tmp_dir).sessions_since_last == 1

      DreamGate.record_session_start(tmp_dir)
      assert DreamGate.read_state(tmp_dir).sessions_since_last == 2
    end
  end

  describe "record_consolidation_complete/3" do
    test "resets session counter and updates totals", %{tmp_dir: tmp_dir} do
      DreamGate.record_session_start(tmp_dir)
      DreamGate.record_session_start(tmp_dir)
      DreamGate.record_session_start(tmp_dir)

      DreamGate.record_consolidation_complete(tmp_dir, 5_000, 0.25)

      state = DreamGate.read_state(tmp_dir)
      assert state.sessions_since_last == 0
      assert state.total_runs == 1
      assert state.total_tokens_spent == 5_000
      assert state.total_cost_usd == 0.25
      assert state.last_consolidated_at != nil
    end
  end

  describe "is_gate_open/2" do
    test "all gates closed on fresh state (no sessions)", %{tmp_dir: tmp_dir} do
      result = DreamGate.is_gate_open(tmp_dir, min_hours: 0, min_sessions: 3)
      assert result.open == false
      assert result.gates.time.passed == true
      assert result.gates.sessions.passed == false
      assert result.gates.lock.passed == true
    end

    test "all gates open after enough sessions and time", %{tmp_dir: tmp_dir} do
      # Record 3 sessions
      for _ <- 1..3, do: DreamGate.record_session_start(tmp_dir)

      result = DreamGate.is_gate_open(tmp_dir, min_hours: 0, min_sessions: 3)
      assert result.open == true
      assert result.gates.time.passed == true
      assert result.gates.sessions.passed == true
      assert result.gates.lock.passed == true
    end

    test "time gate blocks when consolidated recently", %{tmp_dir: tmp_dir} do
      for _ <- 1..5, do: DreamGate.record_session_start(tmp_dir)
      DreamGate.record_consolidation_complete(tmp_dir, 1000, 0.1)

      # Re-record sessions
      for _ <- 1..5, do: DreamGate.record_session_start(tmp_dir)

      result = DreamGate.is_gate_open(tmp_dir, min_hours: 4, min_sessions: 3)
      assert result.open == false
      assert result.gates.time.passed == false
      assert result.gates.sessions.passed == true
    end

    test "lock gate blocks when lock is held", %{tmp_dir: tmp_dir} do
      for _ <- 1..3, do: DreamGate.record_session_start(tmp_dir)

      assert :ok = DreamGate.acquire_lock(tmp_dir)

      result = DreamGate.is_gate_open(tmp_dir, min_hours: 0, min_sessions: 3)
      assert result.open == false
      assert result.gates.lock.passed == false
    end
  end

  describe "acquire_lock/1 and release_lock/1" do
    test "acquires and releases lock", %{tmp_dir: tmp_dir} do
      assert :ok = DreamGate.acquire_lock(tmp_dir)
      assert {:error, :locked} = DreamGate.acquire_lock(tmp_dir)

      assert :ok = DreamGate.release_lock(tmp_dir)
      assert :ok = DreamGate.acquire_lock(tmp_dir)
    end

    test "handles stale locks", %{tmp_dir: tmp_dir} do
      learning_dir = Path.join(tmp_dir, ".claude-flow/learning")
      File.mkdir_p!(learning_dir)

      # Create a lock from 40 minutes ago
      old_ts =
        DateTime.utc_now()
        |> DateTime.add(-40 * 60, :second)
        |> DateTime.to_iso8601()

      lock_data = Jason.encode!(%{acquired_at: old_ts, pid: "12345"})
      File.write!(Path.join(learning_dir, "dream.lock"), lock_data)

      # Should be able to acquire because the existing lock is stale
      assert :ok = DreamGate.acquire_lock(tmp_dir)
    end
  end
end
