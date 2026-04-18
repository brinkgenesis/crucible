defmodule Crucible.KanbanTest do
  use ExUnit.Case, async: true

  alias Crucible.Kanban.MemoryAdapter

  setup do
    start_supervised!({MemoryAdapter, [name: MemoryAdapter]})
    :ok
  end

  describe "create_card/1" do
    test "creates a card with defaults" do
      {:ok, card} = MemoryAdapter.create_card(%{title: "Test card"})
      assert card.title == "Test card"
      assert card.version == 0
      assert card.archived == false
    end
  end

  describe "list_cards/1" do
    test "lists non-archived cards" do
      MemoryAdapter.create_card(%{title: "Active"})
      MemoryAdapter.create_card(%{title: "Archived"})

      # Archive one
      {:ok, cards} = MemoryAdapter.list_cards()
      archived = Enum.find(cards, &(&1.title == "Archived"))
      MemoryAdapter.archive_card(archived.id)

      {:ok, active} = MemoryAdapter.list_cards(archived: false)
      assert length(active) == 1
      assert hd(active).title == "Active"
    end
  end

  describe "get_card/1" do
    test "returns card by ID" do
      {:ok, card} = MemoryAdapter.create_card(%{title: "Find me"})
      assert {:ok, found} = MemoryAdapter.get_card(card.id)
      assert found.title == "Find me"
    end

    test "returns not_found for missing card" do
      assert {:error, :not_found} = MemoryAdapter.get_card("nonexistent")
    end
  end

  describe "move_card/3" do
    test "moves card to new column with version check" do
      {:ok, card} = MemoryAdapter.create_card(%{title: "Move me", column: "unassigned"})
      {:ok, moved} = MemoryAdapter.move_card(card.id, "todo", 0)
      assert moved.column == "todo"
      assert moved.version == 1
    end

    test "rejects version mismatch" do
      {:ok, card} = MemoryAdapter.create_card(%{title: "Version test"})
      assert {:error, :version_conflict} = MemoryAdapter.move_card(card.id, "todo", 99)
    end
  end

  describe "update_card/3" do
    test "updates card fields" do
      {:ok, card} = MemoryAdapter.create_card(%{title: "Update me"})
      {:ok, updated} = MemoryAdapter.update_card(card.id, %{title: "Updated"}, 0)
      assert updated.title == "Updated"
      assert updated.version == 1
    end
  end

  describe "archive_card/1 and restore_card/1" do
    test "archives and restores" do
      {:ok, card} = MemoryAdapter.create_card(%{title: "Archive test"})

      {:ok, archived} = MemoryAdapter.archive_card(card.id)
      assert archived.archived == true

      {:ok, restored} = MemoryAdapter.restore_card(card.id)
      assert restored.archived == false
    end
  end

  describe "delete_card/1" do
    test "deletes card" do
      {:ok, card} = MemoryAdapter.create_card(%{title: "Delete me"})
      assert :ok = MemoryAdapter.delete_card(card.id)
      assert {:error, :not_found} = MemoryAdapter.get_card(card.id)
    end

    test "returns not_found for missing card" do
      assert {:error, :not_found} = MemoryAdapter.delete_card("nonexistent")
    end
  end

  describe "card_history/2" do
    test "returns empty for new card" do
      {:ok, card} = MemoryAdapter.create_card(%{title: "History test"})
      assert {:ok, []} = MemoryAdapter.card_history(card.id)
    end
  end
end
