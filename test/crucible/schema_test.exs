defmodule Crucible.SchemaTest do
  use ExUnit.Case, async: true

  alias Crucible.Schema.{Card, CardEvent, WorkflowRun, TraceEvent, User}

  describe "Card changeset" do
    test "valid changeset" do
      changeset = Card.changeset(%Card{}, %{title: "Fix bug", column: "todo"})
      assert changeset.valid?
    end

    test "requires title and column" do
      changeset = Card.changeset(%Card{}, %{})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset, :title)
      assert "can't be blank" in errors_on(changeset, :column)
    end

    test "validates column values" do
      changeset = Card.changeset(%Card{}, %{title: "X", column: "invalid"})
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset, :column)
    end
  end

  describe "CardEvent changeset" do
    test "valid changeset" do
      changeset = CardEvent.changeset(%CardEvent{}, %{card_id: "c1", event_type: "card.created"})
      assert changeset.valid?
    end
  end

  describe "WorkflowRun changeset" do
    test "valid changeset" do
      changeset =
        WorkflowRun.changeset(%WorkflowRun{}, %{
          workflow_name: "deploy",
          task_description: "Deploy to prod"
        })

      assert changeset.valid?
    end

    test "requires workflow_name and task_description" do
      changeset = WorkflowRun.changeset(%WorkflowRun{}, %{})
      refute changeset.valid?
    end
  end

  describe "TraceEvent changeset" do
    test "valid changeset" do
      changeset =
        TraceEvent.changeset(%TraceEvent{}, %{
          timestamp: DateTime.utc_now(),
          trace_id: "t1",
          event_type: "phase.start"
        })

      assert changeset.valid?
    end
  end

  describe "User changeset" do
    test "valid changeset" do
      changeset = User.changeset(%User{}, %{email: "test@example.com"})
      assert changeset.valid?
    end

    test "validates role" do
      changeset = User.changeset(%User{}, %{email: "x@x.com", role: "superuser"})
      refute changeset.valid?
    end
  end

  # Helper to extract error messages from a changeset
  defp errors_on(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {msg, _opts} -> msg end)
  end
end
