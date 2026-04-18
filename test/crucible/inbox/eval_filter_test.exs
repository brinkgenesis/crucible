defmodule Crucible.Inbox.EvalFilterTest do
  use ExUnit.Case, async: true

  alias Crucible.Inbox.EvalFilter

  describe "weighted_average/2" do
    test "equal weights gives simple average" do
      dims = [
        %{criterion: "actionability", score: 8.0, note: ""},
        %{criterion: "relevance", score: 6.0, note: ""},
        %{criterion: "specificity", score: 4.0, note: ""}
      ]

      avg = EvalFilter.weighted_average(dims, [])
      assert_in_delta avg, 6.0, 0.01
    end

    test "research label boosts strategic_value" do
      dims = [
        %{criterion: "actionability", score: 3.0, note: ""},
        %{criterion: "strategic_value", score: 9.0, note: ""},
        %{criterion: "novelty", score: 8.0, note: ""}
      ]

      plain = EvalFilter.weighted_average(dims, [])
      research = EvalFilter.weighted_average(dims, ["research"])

      # Research should produce higher score since strategic_value is boosted
      assert research > plain
    end

    test "empty dimensions returns 0" do
      assert EvalFilter.weighted_average([], []) == 0.0
    end
  end

  describe "assign_bucket/1" do
    test "scores >= 7.0 auto-promote" do
      assert EvalFilter.assign_bucket(7.0) == "auto-promote"
      assert EvalFilter.assign_bucket(9.5) == "auto-promote"
    end

    test "scores 4.0-6.9 are review" do
      assert EvalFilter.assign_bucket(4.0) == "review"
      assert EvalFilter.assign_bucket(6.9) == "review"
    end

    test "scores 2.0-3.9 are low-priority" do
      assert EvalFilter.assign_bucket(2.0) == "low-priority"
      assert EvalFilter.assign_bucket(3.5) == "low-priority"
    end

    test "scores below 2.0 are dismissed" do
      assert EvalFilter.assign_bucket(1.9) == "dismiss"
      assert EvalFilter.assign_bucket(0.0) == "dismiss"
    end
  end

  describe "evaluate/2 with mock router" do
    test "parses valid LLM response into eval result" do
      valid_json =
        Jason.encode!(%{
          "dimensions" => [
            %{"criterion" => "actionability", "score" => 8, "note" => "clear action"},
            %{"criterion" => "relevance", "score" => 7, "note" => "related"},
            %{"criterion" => "specificity", "score" => 6, "note" => "specific"},
            %{"criterion" => "strategic_value", "score" => 4, "note" => "moderate"}
          ],
          "labels" => ["feature", "tooling"],
          "feedback" => "Useful feature request"
        })

      mock_router = fn _req -> {:ok, %{text: valid_json}} end

      item = %{
        id: "item-1",
        title: "Add caching",
        original_text: "We should add caching",
        summary: nil
      }

      assert {:ok, result} = EvalFilter.evaluate(item, mock_router)
      assert result.item_id == "item-1"
      assert length(result.dimensions) == 4
      assert result.labels == ["feature", "tooling"]
      assert result.average_score > 0
      assert result.bucket in ["auto-promote", "review", "low-priority", "dismiss"]
    end

    test "returns fallback on unparseable response" do
      mock_router = fn _req -> {:ok, %{text: "I can't evaluate this"}} end

      item = %{id: "item-2", title: "Test", original_text: "test content", summary: nil}
      assert {:ok, result} = EvalFilter.evaluate(item, mock_router)
      assert result.average_score == 5.0
      assert result.bucket == "review"
    end

    test "returns fallback on router error" do
      mock_router = fn _req -> {:error, :timeout} end

      item = %{id: "item-3", title: "Test", original_text: "test", summary: nil}
      assert {:ok, result} = EvalFilter.evaluate(item, mock_router)
      assert result.bucket == "review"
    end

    test "uses complexity 2 for cheap evaluation" do
      test_pid = self()
      ref = make_ref()

      mock_router = fn req ->
        send(test_pid, {ref, req})

        {:ok,
         %{
           text:
             Jason.encode!(%{
               "dimensions" => [
                 %{"criterion" => "actionability", "score" => 5, "note" => ""},
                 %{"criterion" => "relevance", "score" => 5, "note" => ""},
                 %{"criterion" => "specificity", "score" => 5, "note" => ""}
               ],
               "labels" => [],
               "feedback" => "ok"
             })
         }}
      end

      EvalFilter.evaluate(%{id: "x", title: "T", original_text: "t", summary: nil}, mock_router)

      assert_receive {^ref, req}
      assert req.complexity_hint == 2
      assert req.strategy == :cost
    end
  end
end
