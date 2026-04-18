defmodule Crucible.TokenValueTest do
  use ExUnit.Case, async: true

  alias Crucible.TokenValue

  describe "tiers/0" do
    test "returns 7 tiers in order" do
      tiers = TokenValue.tiers()
      assert length(tiers) == 7
      assert List.first(tiers) == :access
      assert List.last(tiers) == :asset
    end
  end

  describe "weight/1" do
    test "access is lowest weight" do
      assert TokenValue.weight(:access) == 1
    end

    test "asset is highest weight" do
      assert TokenValue.weight(:asset) == 7
    end

    test "weights increase monotonically" do
      weights = Enum.map(TokenValue.tiers(), &TokenValue.weight/1)
      assert weights == Enum.sort(weights)
    end
  end

  describe "score_note/1" do
    test "lesson note classifies as expert tier" do
      {tier, score} =
        TokenValue.score_note(%{
          type: "lesson",
          content: "Some lesson",
          tags: [],
          priority: "notable"
        })

      assert tier == :expert
      assert is_float(score)
      assert score >= 0.0 and score <= 1.0
    end

    test "decision note with wikilinks classifies as knowledge tier" do
      {tier, _score} =
        TokenValue.score_note(%{
          type: "decision",
          content: "See [[other-note]] for context",
          tags: [],
          priority: "critical"
        })

      assert tier == :knowledge
    end

    test "decision note without links classifies as context tier" do
      {tier, _score} =
        TokenValue.score_note(%{
          type: "decision",
          content: "Simple decision",
          tags: [],
          priority: "background"
        })

      assert tier == :context
    end

    test "handoff note classifies as memory tier" do
      {tier, _score} =
        TokenValue.score_note(%{
          type: "handoff",
          content: "Session handoff",
          tags: [],
          priority: "background"
        })

      assert tier == :memory
    end

    test "preference note classifies as identity tier" do
      {tier, _score} =
        TokenValue.score_note(%{
          type: "preference",
          content: "User prefers X",
          tags: [],
          priority: "notable"
        })

      assert tier == :identity
    end

    test "unknown type classifies as access tier" do
      {tier, _score} =
        TokenValue.score_note(%{
          type: "raw-log",
          content: "trace data",
          tags: [],
          priority: "background"
        })

      assert tier == :access
    end

    test "critical priority scores higher than background" do
      {tier1, score1} =
        TokenValue.score_note(%{
          type: "lesson",
          content: "Important",
          tags: [],
          priority: "critical"
        })

      {tier2, score2} =
        TokenValue.score_note(%{
          type: "lesson",
          content: "Important",
          tags: [],
          priority: "background"
        })

      assert tier1 == tier2
      assert score1 > score2
    end
  end

  describe "rank/1" do
    test "ranks notes by tier and score, highest first" do
      notes = [
        %{type: "handoff", content: "handoff", tags: [], priority: "background"},
        %{type: "decision", content: "decision with [[link]]", tags: [], priority: "critical"},
        %{type: "lesson", content: "lesson", tags: [], priority: "notable"}
      ]

      ranked = TokenValue.rank(notes)
      assert length(ranked) == 3

      tiers = Enum.map(ranked, & &1.value_tier)
      # knowledge > expert > memory
      assert List.first(tiers) == :knowledge
      assert List.last(tiers) == :memory
    end

    test "assigns value_tier and value_score to each note" do
      notes = [%{type: "lesson", content: "test", tags: [], priority: "notable"}]
      [ranked] = TokenValue.rank(notes)
      assert Map.has_key?(ranked, :value_tier)
      assert Map.has_key?(ranked, :value_score)
    end
  end

  describe "pipeline_metrics/1" do
    test "returns metrics with all required fields" do
      notes = [
        %{type: "lesson", content: "test", tags: [], priority: "notable"},
        %{type: "handoff", content: "test", tags: [], priority: "background"},
        %{type: "decision", content: "test with [[link]]", tags: [], priority: "critical"}
      ]

      metrics = TokenValue.pipeline_metrics(notes)
      assert metrics.total_notes == 3
      assert is_float(metrics.transformation_ratio)
      assert is_float(metrics.avg_value)
      assert is_map(metrics.by_tier)
    end

    test "empty notes returns zero metrics" do
      metrics = TokenValue.pipeline_metrics([])
      assert metrics.total_notes == 0
      assert metrics.transformation_ratio == 0.0
      assert metrics.avg_value == 0.0
    end
  end
end
