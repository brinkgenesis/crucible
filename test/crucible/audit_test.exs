defmodule Crucible.AuditTest do
  use Crucible.DataCase, async: true

  alias Crucible.Audit
  alias Crucible.Schema.AuditEvent

  describe "health_check/0" do
    test "returns zero count and nil timestamp when no events exist" do
      result = Audit.health_check()

      assert result.event_count == 0
      assert result.latest_timestamp == nil
    end

    test "returns count and timestamp for a single event" do
      {:ok, event} =
        %AuditEvent{}
        |> AuditEvent.changeset(%{
          entity_type: "policy",
          entity_id: "p1",
          event_type: "created"
        })
        |> Repo.insert()

      result = Audit.health_check()

      assert result.event_count == 1
      assert result.latest_timestamp == event.inserted_at
    end

    test "returns correct count and latest timestamp for multiple events" do
      {:ok, _first} =
        %AuditEvent{}
        |> AuditEvent.changeset(%{
          entity_type: "policy",
          entity_id: "p1",
          event_type: "created"
        })
        |> Repo.insert()

      # Small delay to ensure different timestamps
      Process.sleep(10)

      {:ok, second} =
        %AuditEvent{}
        |> AuditEvent.changeset(%{
          entity_type: "budget",
          entity_id: "b1",
          event_type: "updated"
        })
        |> Repo.insert()

      result = Audit.health_check()

      assert result.event_count == 2
      assert result.latest_timestamp == second.inserted_at
    end
  end
end
