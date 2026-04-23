defmodule Crucible.RouterTest do
  @moduledoc "Unit tests for Classifier + Strategy + CostTable — no network."
  use ExUnit.Case, async: true

  alias Crucible.Router
  alias Crucible.Router.{Classifier, CostTable, QuotaTracker, Strategy}

  # ── Classifier ────────────────────────────────────────────────────────

  describe "Classifier.classify/2" do
    test "hint short-circuits prompt analysis" do
      assert %{complexity: 7, reasoning: reason} = Classifier.classify("whatever", 7)
      assert reason =~ "hint"
    end

    test "architecture prompts score 9-10" do
      r = Classifier.classify("design system architecture with tradeoff analysis")
      assert r.complexity >= 9
      assert r.category == "architecture"
    end

    test "debug/bug prompts score 7-8" do
      r = Classifier.classify("debug this performance issue and fix the bug")
      assert r.complexity in 7..8
      assert r.category == "complex-coding"
    end

    test "implement prompts score 5-6" do
      r = Classifier.classify("implement a new function to parse JSON")
      assert r.complexity in 5..6
      assert r.category == "coding"
    end

    test "summarize prompts score 3-4" do
      r = Classifier.classify("summarize this document")
      assert r.complexity in 3..4
      assert r.category == "general"
    end

    test "classify prompts score 1-2" do
      r = Classifier.classify("classify this as positive or negative")
      assert r.complexity <= 2
      assert r.category == "trivial"
    end

    test "non-integer hint falls back to prompt analysis" do
      r = Classifier.classify("hello", 7.5)
      assert is_integer(r.complexity)
      assert r.complexity != 7.5
    end
  end

  # ── Strategy ─────────────────────────────────────────────────────────

  describe "Strategy.select/2" do
    test "cost: trivial → Haiku" do
      r = Strategy.select(1, :cost)
      assert r.model_id == "claude-haiku-4-5-20251001"
      assert r.provider == "anthropic"
    end

    test "cost: general → Gemini Flash" do
      r = Strategy.select(3, :cost)
      assert r.model_id == "gemini-2.5-flash"
      assert r.provider == "google"
    end

    test "cost: coding → MiniMax M2" do
      r = Strategy.select(5, :cost)
      assert r.model_id == "MiniMax-M2"
      assert r.provider == "minimax"
    end

    test "cost: complex-coding → Sonnet" do
      r = Strategy.select(7, :cost)
      assert r.model_id == "claude-sonnet-4-5-20250929"
    end

    test "cost: architecture → Opus" do
      r = Strategy.select(10, :cost)
      assert r.model_id == "claude-opus-4-7"
    end

    test "quality coding → Sonnet, not MiniMax" do
      r = Strategy.select(5, :quality)
      assert r.model_id == "claude-sonnet-4-5-20250929"
    end

    test "speed coding → MiniMax" do
      r = Strategy.select(5, :speed)
      assert r.model_id == "MiniMax-M2"
    end
  end

  describe "Strategy.resolve_profile/1" do
    test "deep_reasoning → quality" do
      assert Strategy.resolve_profile(:deep_reasoning) == :quality
    end

    test "throughput → cost" do
      assert Strategy.resolve_profile(:throughput) == :cost
    end

    test "verification → quality" do
      assert Strategy.resolve_profile(:verification) == :quality
    end

    test "scout → speed" do
      assert Strategy.resolve_profile(:scout) == :speed
    end

    test "yolo_classifier → cost" do
      assert Strategy.resolve_profile(:yolo_classifier) == :cost
    end
  end

  # ── CostTable ────────────────────────────────────────────────────────

  describe "CostTable" do
    test "every expected model is registered" do
      for id <- [
            "claude-opus-4-7",
            "claude-opus-4-6",
            "claude-sonnet-4-6",
            "claude-sonnet-4-5-20250929",
            "claude-haiku-4-5-20251001",
            "MiniMax-M2",
            "gemini-2.5-flash",
            "local-ollama"
          ] do
        assert %{id: ^id} = CostTable.get(id)
      end
    end

    test "estimate_cost for Opus is 15+75 per million" do
      assert_in_delta CostTable.estimate_cost("claude-opus-4-7", 1_000_000, 1_000_000),
                      15.0 + 75.0,
                      0.001
    end

    test "MiniMax M2 is substantially cheaper than Sonnet" do
      minimax = CostTable.estimate_cost("MiniMax-M2", 1_000_000, 1_000_000)
      sonnet = CostTable.estimate_cost("claude-sonnet-4-5-20250929", 1_000_000, 1_000_000)
      assert minimax < sonnet / 10
    end

    test "unknown model returns 0.0" do
      assert CostTable.estimate_cost("what-even-is-this", 1_000, 1_000) == 0.0
    end
  end

  # ── Router wiring ────────────────────────────────────────────────────

  describe "Router.choose_route/2" do
    test "force_model short-circuits strategy" do
      route = Router.choose_route(%{force_model: "claude-opus-4-6"}, %{})
      assert route.model_id == "claude-opus-4-6"
      assert route.provider == "anthropic"
    end

    test "routing profile overrides strategy keyword" do
      classification = Classifier.classify("explain this", nil)
      route = Router.choose_route(%{routing_profile: :deep_reasoning}, classification)
      # Deep-reasoning = quality, complexity ~3-4 for "explain" → Sonnet
      assert route.model_id == "claude-sonnet-4-5-20250929"
    end

    test "default strategy is cost" do
      classification = %{complexity: 3, category: "general"}
      route = Router.choose_route(%{}, classification)
      assert route.provider == "google"
    end
  end

  describe "QuotaTracker" do
    setup do
      QuotaTracker.record_success("anthropic")
      QuotaTracker.record_success("google")
      :ok
    end

    test "records and clears exhausted state" do
      refute QuotaTracker.provider_exhausted?("anthropic")
      QuotaTracker.record_exhausted("anthropic", 100)
      # give the cast time to land
      Process.sleep(50)
      assert QuotaTracker.provider_exhausted?("anthropic")
      QuotaTracker.record_success("anthropic")
      Process.sleep(50)
      refute QuotaTracker.provider_exhausted?("anthropic")
    end

    test "is_model_exhausted? checks provider via CostTable" do
      QuotaTracker.record_success("google")
      refute QuotaTracker.is_model_exhausted?("gemini-2.5-flash")

      QuotaTracker.record_exhausted("google", 200)
      Process.sleep(50)
      assert QuotaTracker.is_model_exhausted?("gemini-2.5-flash")
      QuotaTracker.record_success("google")
    end
  end
end
