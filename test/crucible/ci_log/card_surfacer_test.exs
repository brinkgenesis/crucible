defmodule Crucible.CiLog.CardSurfacerTest do
  use Crucible.DataCase, async: true

  alias Crucible.CiLog.CardSurfacer
  alias Crucible.Schema.Card

  defp make_analysis(overrides \\ %{}) do
    Map.merge(
      %{
        category: "test_failure",
        severity: "critical",
        title: "Login test broken",
        summary: "The login test fails due to a missing mock.",
        suggested_fix: "Add the user mock fixture.",
        is_recurring: false
      },
      overrides
    )
  end

  defp make_context(overrides \\ %{}) do
    Map.merge(%{run_id: "run-42", workflow_name: "CI Tests"}, overrides)
  end

  describe "surface/2" do
    test "skips info severity" do
      analysis = make_analysis(%{severity: "info"})
      assert {:ok, nil} = CardSurfacer.surface(analysis, make_context())
    end

    test "creates a new card for warning severity" do
      analysis = make_analysis(%{severity: "warning"})
      assert {:ok, card_id} = CardSurfacer.surface(analysis, make_context())
      assert is_binary(card_id)

      card = Repo.get(Card, card_id)
      assert card.title == "[CI] test_failure: Login test broken"
      assert card.column == "unassigned"
      assert card.metadata["source"] == "ci-log-analyzer"
      assert card.metadata["run_id"] == "run-42"
      assert card.metadata["workflow_name"] == "CI Tests"
    end

    test "creates a new card for critical severity" do
      analysis = make_analysis(%{severity: "critical"})
      assert {:ok, card_id} = CardSurfacer.surface(analysis, make_context())
      assert is_binary(card_id)

      card = Repo.get(Card, card_id)
      assert card.title =~ "[CI]"
      assert card.metadata["severity"] == "critical"
    end

    test "deduplicates: returns existing card id for non-recurring match" do
      analysis = make_analysis(%{severity: "warning", is_recurring: false})
      context = make_context()

      {:ok, first_id} = CardSurfacer.surface(analysis, context)
      {:ok, second_id} = CardSurfacer.surface(analysis, context)

      assert first_id == second_id
    end

    test "updates occurrences for recurring issues" do
      analysis = make_analysis(%{severity: "warning", is_recurring: true})
      context = make_context()

      {:ok, first_id} = CardSurfacer.surface(analysis, context)

      # Second surface should bump occurrences
      {:ok, second_id} = CardSurfacer.surface(analysis, make_context(%{run_id: "run-43"}))

      assert first_id == second_id

      card = Repo.get(Card, first_id)
      assert card.metadata["occurrences"] == 2
    end

    test "recurring update uses latest run_id" do
      analysis = make_analysis(%{severity: "warning", is_recurring: true})

      {:ok, card_id} = CardSurfacer.surface(analysis, make_context(%{run_id: "run-100"}))
      {:ok, ^card_id} = CardSurfacer.surface(analysis, make_context(%{run_id: "run-101"}))

      card = Repo.get(Card, card_id)
      assert card.metadata["run_id"] == "run-101"
    end

    test "does not surface for archived cards with same title" do
      analysis = make_analysis(%{severity: "warning"})
      context = make_context()

      # Create and archive a card with the same title
      {:ok, first_id} = CardSurfacer.surface(analysis, context)

      Repo.get(Card, first_id)
      |> Card.changeset(%{archived: true, archived_at: DateTime.utc_now()})
      |> Repo.update!()

      # Should create a new card since the old one is archived
      {:ok, second_id} = CardSurfacer.surface(analysis, make_context(%{run_id: "run-new"}))
      assert second_id != first_id
    end
  end
end
