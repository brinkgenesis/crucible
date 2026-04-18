defmodule Crucible.CircuitBreakerTest do
  use ExUnit.Case, async: true

  alias Crucible.CircuitBreaker

  setup do
    tmp = Path.join(System.tmp_dir!(), "cb_test_#{:rand.uniform(10000)}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{home: tmp}
  end

  describe "check/2" do
    test "allows when no state exists", %{home: home} do
      assert {:ok, :allowed} = CircuitBreaker.check(home, "my-workflow")
    end

    test "allows in closed state after failures below threshold", %{home: home} do
      CircuitBreaker.record(home, "wf", false)
      CircuitBreaker.record(home, "wf", false)
      assert {:ok, :allowed} = CircuitBreaker.check(home, "wf")
    end
  end

  describe "record/3" do
    test "opens circuit after threshold failures", %{home: home} do
      CircuitBreaker.record(home, "wf", false)
      CircuitBreaker.record(home, "wf", false)
      CircuitBreaker.record(home, "wf", false)

      assert {:blocked, reason} = CircuitBreaker.check(home, "wf")
      assert reason =~ "Circuit open"
      assert reason =~ "cooldown remaining"
    end

    test "resets on success", %{home: home} do
      CircuitBreaker.record(home, "wf", false)
      CircuitBreaker.record(home, "wf", false)
      CircuitBreaker.record(home, "wf", true)

      state = CircuitBreaker.get_state(home, "wf")
      assert state.consecutive_failures == 0
      assert state.state == :closed
    end

    test "isolates per workflow name", %{home: home} do
      for _ <- 1..3, do: CircuitBreaker.record(home, "wf-a", false)

      assert {:blocked, _} = CircuitBreaker.check(home, "wf-a")
      assert {:ok, :allowed} = CircuitBreaker.check(home, "wf-b")
    end
  end

  describe "half_open canary" do
    test "canary failure extends cooldown", %{home: home} do
      for _ <- 1..3, do: CircuitBreaker.record(home, "wf", false)

      # Manually expire cooldown
      store_path = Path.join([home, ".claude-flow", "learning", "circuit-breakers.json"])
      {:ok, raw} = File.read(store_path)
      {:ok, data} = Jason.decode(raw)
      data = put_in(data, ["wf", "openedAt"], System.system_time(:millisecond) - 31 * 60_000)
      File.write!(store_path, Jason.encode!(data))

      # Transition to half_open
      assert {:ok, :allowed} = CircuitBreaker.check(home, "wf")
      assert CircuitBreaker.get_state(home, "wf").state == :half_open

      # Canary failure → back to open with extended cooldown
      CircuitBreaker.record(home, "wf", false)
      state = CircuitBreaker.get_state(home, "wf")
      assert state.state == :open
      assert state.cooldown_ms == 60 * 60_000
    end

    test "canary success resets to closed", %{home: home} do
      for _ <- 1..3, do: CircuitBreaker.record(home, "wf", false)

      store_path = Path.join([home, ".claude-flow", "learning", "circuit-breakers.json"])
      {:ok, raw} = File.read(store_path)
      {:ok, data} = Jason.decode(raw)
      data = put_in(data, ["wf", "openedAt"], System.system_time(:millisecond) - 31 * 60_000)
      File.write!(store_path, Jason.encode!(data))

      CircuitBreaker.check(home, "wf")
      CircuitBreaker.record(home, "wf", true)

      state = CircuitBreaker.get_state(home, "wf")
      assert state.state == :closed
      assert state.consecutive_failures == 0
    end
  end

  describe "reset/2" do
    test "removes circuit state", %{home: home} do
      for _ <- 1..3, do: CircuitBreaker.record(home, "wf", false)
      assert {:blocked, _} = CircuitBreaker.check(home, "wf")

      CircuitBreaker.reset(home, "wf")
      assert {:ok, :allowed} = CircuitBreaker.check(home, "wf")
      assert CircuitBreaker.get_state(home, "wf") == nil
    end
  end

  describe "persistence" do
    test "round-trips through JSON", %{home: home} do
      CircuitBreaker.record(home, "wf", false)
      CircuitBreaker.record(home, "wf", false)

      state = CircuitBreaker.get_state(home, "wf")
      assert state.consecutive_failures == 2
      assert state.state == :closed
    end
  end
end
