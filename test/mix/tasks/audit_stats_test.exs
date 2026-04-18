defmodule Mix.Tasks.AuditStatsTest do
  use Crucible.DataCase, async: true

  alias Crucible.Repo
  alias Crucible.Schema.AuditEvent

  import ExUnit.CaptureIO

  describe "run/1" do
    test "prints 'no events' when table is empty" do
      output = capture_io(fn -> Mix.Tasks.AuditStats.run([]) end)
      assert output =~ "No audit events found."
    end

    test "prints counts grouped by entity_type, sorted descending" do
      seed_events([
        {"policy", "created"},
        {"policy", "updated"},
        {"policy", "deleted"},
        {"budget", "created"},
        {"budget", "updated"},
        {"workflow", "created"}
      ])

      output = capture_io(fn -> Mix.Tasks.AuditStats.run([]) end)

      assert output =~ "entity_type"
      assert output =~ "count"
      assert output =~ "policy"
      assert output =~ "budget"
      assert output =~ "workflow"
      assert output =~ "TOTAL"
      assert output =~ "| 6"

      # policy (3) should appear before budget (2) before workflow (1)
      policy_pos = :binary.match(output, "policy") |> elem(0)
      budget_pos = :binary.match(output, "budget") |> elem(0)
      workflow_pos = :binary.match(output, "workflow") |> elem(0)
      assert policy_pos < budget_pos
      assert budget_pos < workflow_pos
    end

    test "filters by --since flag" do
      old_time = ~U[2023-06-15 12:00:00Z]
      new_time = ~U[2024-06-15 12:00:00Z]

      Repo.insert!(%AuditEvent{
        entity_type: "policy",
        entity_id: "old-1",
        event_type: "created",
        occurred_at: old_time
      })

      Repo.insert!(%AuditEvent{
        entity_type: "budget",
        entity_id: "new-1",
        event_type: "created",
        occurred_at: new_time
      })

      output = capture_io(fn -> Mix.Tasks.AuditStats.run(["--since", "2024-01-01"]) end)

      assert output =~ "budget"
      refute output =~ "policy"
      assert output =~ "TOTAL"
      assert output =~ "| 1"
    end

    test "raises on invalid --since date" do
      assert_raise Mix.Error, ~r/Invalid --since date/, fn ->
        Mix.Tasks.AuditStats.run(["--since", "not-a-date"])
      end
    end
  end

  defp seed_events(events) do
    Enum.each(events, fn {entity_type, event_type} ->
      Repo.insert!(%AuditEvent{
        entity_type: entity_type,
        entity_id: "#{entity_type}-#{System.unique_integer([:positive])}",
        event_type: event_type,
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    end)
  end
end
