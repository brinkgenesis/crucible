defmodule Crucible.Inbox.ScannerTest do
  use Crucible.DataCase, async: true

  alias Crucible.Inbox.Scanner
  alias Crucible.Schema.{Card, InboxItem}

  defp insert_item(attrs) do
    defaults = %{
      source: "link",
      source_id: Ecto.UUID.generate(),
      status: "unread",
      title: "Test Item",
      original_text: "Some interesting content about testing",
      ingested_at: DateTime.utc_now()
    }

    %InboxItem{}
    |> InboxItem.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp mock_router(score) do
    fn _req ->
      {:ok,
       %{
         text:
           Jason.encode!(%{
             "dimensions" => [
               %{"criterion" => "actionability", "score" => score, "note" => ""},
               %{"criterion" => "relevance", "score" => score, "note" => ""},
               %{"criterion" => "specificity", "score" => score, "note" => ""},
               %{"criterion" => "strategic_value", "score" => score, "note" => ""}
             ],
             "labels" => ["feature"],
             "feedback" => "test"
           })
       }}
    end
  end

  describe "load_unread/1" do
    test "returns unread items" do
      insert_item(%{title: "Unread one"})
      insert_item(%{title: "Read one", status: "read"})

      unread = Scanner.load_unread()
      assert length(unread) == 1
      assert hd(unread).title == "Unread one"
    end

    test "respects limit" do
      for i <- 1..5, do: insert_item(%{title: "Item #{i}"})

      assert length(Scanner.load_unread(3)) == 3
    end
  end

  describe "scan/1" do
    test "returns empty result when no unread items" do
      assert {:ok, result} = Scanner.scan()
      assert result.total_items == 0
    end

    test "evaluates items and creates cards for high scores" do
      insert_item(%{title: "High scorer"})

      {:ok, result} = Scanner.scan(router_fn: mock_router(8.0))

      assert result.total_items == 1
      assert result.evaluated == 1
      assert result.cards_created == 1
    end

    test "dismisses low-scoring items" do
      insert_item(%{title: "Low scorer"})

      {:ok, result} = Scanner.scan(router_fn: mock_router(1.0))

      assert result.total_items == 1
      assert result.evaluated == 1
      assert result.dismissed == 1
      assert result.cards_created == 0
    end

    test "marks review-tier items as read" do
      insert_item(%{title: "Mid scorer"})

      {:ok, result} = Scanner.scan(router_fn: mock_router(5.0))

      assert result.for_review == 1
      assert result.cards_created == 0
    end

    test "stores eval_result on the inbox item" do
      item = insert_item(%{title: "Eval storage test"})

      Scanner.scan(router_fn: mock_router(7.5))

      updated = Repo.get(InboxItem, item.id)
      assert updated.eval_result != nil
      assert updated.eval_result["average_score"] >= 7.0
    end

    test "updates item status to actioned with card_id for auto-promotes" do
      item = insert_item(%{title: "Actioned test"})

      Scanner.scan(router_fn: mock_router(9.0))

      updated = Repo.get(InboxItem, item.id)
      assert updated.status == "actioned"
      assert updated.card_id != nil

      card = Repo.get(Card, updated.card_id)
      assert card.title =~ "[Inbox]"
      assert card.column == "unassigned"
    end
  end
end
