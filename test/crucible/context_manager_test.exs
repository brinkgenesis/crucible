defmodule Crucible.ContextManagerTest do
  use ExUnit.Case, async: true

  alias Crucible.ContextManager

  @run_id "ctx-test-#{:rand.uniform(100_000)}"

  describe "start_link/1" do
    test "starts a ContextManager for a run" do
      run_id = "cm-start-#{:rand.uniform(100_000)}"
      assert {:ok, pid} = ContextManager.start_link(run_id: run_id)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "rejects duplicate run_id" do
      run_id = "cm-dup-#{:rand.uniform(100_000)}"
      {:ok, pid} = ContextManager.start_link(run_id: run_id)

      assert {:error, {:already_started, ^pid}} =
               ContextManager.start_link(run_id: run_id)

      GenServer.stop(pid)
    end
  end

  describe "record_turn/3" do
    test "records turn data and increments counters" do
      run_id = "cm-turn-#{:rand.uniform(100_000)}"
      {:ok, pid} = ContextManager.start_link(run_id: run_id)

      :ok = ContextManager.record_turn(run_id, 0, %{tokens: 500, role: "assistant", content: "hello"})
      :ok = ContextManager.record_turn(run_id, 0, %{tokens: 300, role: "user", content: "world"})

      stats = ContextManager.stats(run_id)
      assert stats.total_tokens == 800
      assert stats.turn_count == 2

      GenServer.stop(pid)
    end

    test "handles string keys in turn_data" do
      run_id = "cm-strkey-#{:rand.uniform(100_000)}"
      {:ok, pid} = ContextManager.start_link(run_id: run_id)

      :ok = ContextManager.record_turn(run_id, 0, %{"tokens" => 100, "role" => "user", "content" => "hi"})
      # Give the cast time to process
      Process.sleep(10)

      stats = ContextManager.stats(run_id)
      assert stats.total_tokens == 100

      GenServer.stop(pid)
    end

    test "returns :ok for unknown run_id" do
      assert :ok = ContextManager.record_turn("nonexistent-run", 0, %{tokens: 100})
    end
  end

  describe "maybe_summarize/2" do
    test "returns messages unchanged when below threshold" do
      run_id = "cm-nosumm-#{:rand.uniform(100_000)}"
      {:ok, pid} = ContextManager.start_link(run_id: run_id, context_limit: 200_000)

      messages = [%{"role" => "user", "content" => "hello"}]
      assert {:ok, ^messages} = ContextManager.maybe_summarize(run_id, messages)

      GenServer.stop(pid)
    end

    test "returns {:ok, messages} for unknown run_id" do
      messages = [%{"role" => "user", "content" => "test"}]
      assert {:ok, ^messages} = ContextManager.maybe_summarize("unknown-run", messages)
    end
  end

  describe "stats/1" do
    test "returns stats map for active run" do
      run_id = "cm-stats-#{:rand.uniform(100_000)}"
      {:ok, pid} = ContextManager.start_link(run_id: run_id, context_limit: 100_000)

      stats = ContextManager.stats(run_id)
      assert stats.run_id == run_id
      assert stats.total_tokens == 0
      assert stats.context_limit == 100_000
      assert stats.usage_ratio == 0.0
      assert stats.turn_count == 0
      assert stats.summary_count == 0

      GenServer.stop(pid)
    end

    test "returns nil for unknown run_id" do
      assert nil == ContextManager.stats("nonexistent-run")
    end

    test "usage_ratio increases with recorded turns" do
      run_id = "cm-ratio-#{:rand.uniform(100_000)}"
      {:ok, pid} = ContextManager.start_link(run_id: run_id, context_limit: 1000)

      ContextManager.record_turn(run_id, 0, %{tokens: 500})
      # Give the cast time to process
      Process.sleep(10)

      stats = ContextManager.stats(run_id)
      assert stats.usage_ratio == 0.5

      GenServer.stop(pid)
    end
  end

  describe "context_limit validation" do
    test "accepts positive context_limit" do
      run_id = "cm-limit-#{:rand.uniform(100_000)}"
      {:ok, pid} = ContextManager.start_link(run_id: run_id, context_limit: 50_000)

      stats = ContextManager.stats(run_id)
      assert stats.context_limit == 50_000

      GenServer.stop(pid)
    end

    test "defaults to 180_000 tokens" do
      run_id = "cm-default-#{:rand.uniform(100_000)}"
      {:ok, pid} = ContextManager.start_link(run_id: run_id)

      stats = ContextManager.stats(run_id)
      assert stats.context_limit == 180_000

      GenServer.stop(pid)
    end
  end
end
