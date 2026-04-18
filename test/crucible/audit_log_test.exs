defmodule Crucible.AuditLogTest do
  use Crucible.DataCase

  alias Crucible.AuditLog
  alias Crucible.Schema.AuditEvent

  describe "log/5" do
    test "inserts an audit event with required fields" do
      assert :ok = AuditLog.log("card", "card-123", "created")

      [event] = Repo.all(AuditEvent)
      assert event.entity_type == "card"
      assert event.entity_id == "card-123"
      assert event.event_type == "created"
      assert event.payload == %{}
      assert is_nil(event.actor)
    end

    test "includes actor when provided" do
      assert :ok = AuditLog.log("config", "budget", "updated", %{}, actor: "liveview:ConfigLive")

      [event] = Repo.all(AuditEvent)
      assert event.actor == "liveview:ConfigLive"
    end

    test "includes payload map" do
      payload = %{"key" => "DAILY_BUDGET", "value" => "100"}
      assert :ok = AuditLog.log("config", "env", "updated", payload)

      [event] = Repo.all(AuditEvent)
      assert event.payload["key"] == "DAILY_BUDGET"
    end

    test "converts entity_id to string" do
      assert :ok = AuditLog.log("card", 42, "deleted")

      [event] = Repo.all(AuditEvent)
      assert event.entity_id == "42"
    end

    test "sets occurred_at timestamp" do
      assert :ok = AuditLog.log("card", "1", "created")

      [event] = Repo.all(AuditEvent)
      assert %DateTime{} = event.occurred_at
    end

    test "fails silently and returns :ok on error" do
      # nil entity_type should fail changeset validation but not crash
      assert :ok = AuditLog.log(nil, "1", "created")
    end
  end

  describe "diff_payload/2" do
    test "captures before/after for changed fields" do
      card = %Crucible.Schema.Card{title: "Old Title", column: "todo"}
      changeset = Ecto.Changeset.change(card, title: "New Title")

      result = AuditLog.diff_payload(changeset)

      assert result.changes.title == %{from: "Old Title", to: "New Title"}
      refute Map.has_key?(result.changes, :column)
    end

    test "merges extra data into payload" do
      card = %Crucible.Schema.Card{title: "T"}
      changeset = Ecto.Changeset.change(card, title: "T2")

      result = AuditLog.diff_payload(changeset, %{actor: "system"})

      assert result.actor == "system"
      assert result.changes.title
    end

    test "serializes Decimal values to strings" do
      # Card has estimated_cost_usd as :decimal
      card = %Crucible.Schema.Card{estimated_cost_usd: Decimal.new("50.00")}
      changeset = Ecto.Changeset.change(card, estimated_cost_usd: Decimal.new("100.00"))

      result = AuditLog.diff_payload(changeset)

      assert result.changes.estimated_cost_usd.from == "50.00"
      assert result.changes.estimated_cost_usd.to == "100.00"
    end

    test "returns empty changes for unchanged changeset" do
      card = %Crucible.Schema.Card{title: "Same"}
      changeset = Ecto.Changeset.change(card, %{})

      result = AuditLog.diff_payload(changeset)
      assert result.changes == %{}
    end

    test "skips updated_at and inserted_at metadata fields" do
      card = %Crucible.Schema.Card{title: "T"}
      changeset = Ecto.Changeset.change(card, title: "T2", updated_at: ~N[2026-01-01 00:00:00])

      result = AuditLog.diff_payload(changeset)

      assert Map.has_key?(result.changes, :title)
      refute Map.has_key?(result.changes, :updated_at)
    end
  end

  describe "history/3" do
    test "returns events for an entity" do
      AuditLog.log("card", "card-1", "created")
      AuditLog.log("card", "card-1", "updated")
      AuditLog.log("card", "card-2", "created")

      events = AuditLog.history("card", "card-1")
      assert length(events) == 2
      event_types = Enum.map(events, & &1.event_type) |> Enum.sort()
      assert event_types == ["created", "updated"]
    end

    test "returns empty list for unknown entity" do
      assert [] = AuditLog.history("card", "nonexistent")
    end

    test "respects limit option" do
      for i <- 1..10 do
        AuditLog.log("card", "card-limited", "event_#{i}")
      end

      events = AuditLog.history("card", "card-limited", limit: 3)
      assert length(events) == 3
    end
  end
end
