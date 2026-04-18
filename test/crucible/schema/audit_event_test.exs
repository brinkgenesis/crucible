defmodule Crucible.Schema.AuditEventTest do
  use ExUnit.Case, async: true

  alias Crucible.Schema.AuditEvent

  describe "changeset/2" do
    test "valid with required fields" do
      cs = AuditEvent.changeset(%AuditEvent{}, %{
        entity_type: "card",
        entity_id: "abc-123",
        event_type: "created"
      })
      assert cs.valid?
    end

    test "invalid without entity_type" do
      cs = AuditEvent.changeset(%AuditEvent{}, %{entity_id: "1", event_type: "x"})
      refute cs.valid?
      assert cs.errors[:entity_type]
    end

    test "invalid without entity_id" do
      cs = AuditEvent.changeset(%AuditEvent{}, %{entity_type: "card", event_type: "x"})
      refute cs.valid?
      assert cs.errors[:entity_id]
    end

    test "invalid without event_type" do
      cs = AuditEvent.changeset(%AuditEvent{}, %{entity_type: "card", entity_id: "1"})
      refute cs.valid?
      assert cs.errors[:event_type]
    end

    test "accepts optional actor and payload" do
      cs = AuditEvent.changeset(%AuditEvent{}, %{
        entity_type: "config",
        entity_id: "budget",
        event_type: "updated",
        actor: "liveview:ConfigLive",
        payload: %{"key" => "value"}
      })
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :actor) == "liveview:ConfigLive"
    end

    test "defaults payload to empty map" do
      event = %AuditEvent{}
      assert event.payload == %{}
    end
  end
end
