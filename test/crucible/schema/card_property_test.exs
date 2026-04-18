defmodule Crucible.Schema.CardPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Crucible.Schema.Card
  import Crucible.Generators

  property "valid column + title produces valid changeset" do
    check all(
            column <- card_column(),
            title <- card_title()
          ) do
      cs =
        Card.changeset(%Card{id: Ecto.UUID.generate()}, %{
          column: column,
          title: title,
          workflow_type: "coding-sprint"
        })

      assert cs.valid?
    end
  end

  property "invalid column is rejected" do
    check all(column <- invalid_card_column()) do
      cs =
        Card.changeset(%Card{id: Ecto.UUID.generate()}, %{
          column: column,
          title: "test card",
          workflow_type: "coding-sprint"
        })

      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :column)
    end
  end

  property "title must be 1..500 characters" do
    check all(len <- integer(501..600)) do
      long_title = String.duplicate("a", len)

      cs =
        Card.changeset(%Card{id: Ecto.UUID.generate()}, %{
          column: "todo",
          title: long_title,
          workflow_type: "coding-sprint"
        })

      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :title)
    end
  end

  property "empty title is rejected" do
    cs =
      Card.changeset(%Card{id: Ecto.UUID.generate()}, %{
        column: "todo",
        title: "",
        workflow_type: "coding-sprint"
      })

    refute cs.valid?
  end
end
