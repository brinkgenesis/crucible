defmodule Crucible.TraceReaderDbTest do
  use Crucible.DataCase, async: true

  alias Crucible.Schema.{TraceEvent, WorkflowRun}
  alias Crucible.TraceReader

  test "infers terminal status and duration from trace events when workflow_runs row is stale" do
    run_id = "stale-running-run"
    created_at = ~U[2026-03-04 21:26:38Z]
    finished_at = ~U[2026-03-04 21:36:11Z]

    %WorkflowRun{}
    |> Ecto.Changeset.change(%{
      run_id: run_id,
      workflow_name: "coding-sprint",
      task_description: "Repair stale workflow status",
      status: "running",
      created_at: created_at,
      updated_at: created_at
    })
    |> Ecto.Changeset.put_embed(:phases, [
      %{id: "phase-0", name: "sprint", type: "team", phase_index: 0, status: "completed"},
      %{id: "phase-1", name: "review", type: "session", phase_index: 1, status: "pending"}
    ])
    |> Repo.insert!()

    Repo.insert!(%TraceEvent{
      timestamp: finished_at,
      trace_id: "trace-stale-running-run",
      run_id: run_id,
      event_type: "checkpoint",
      detail: "Run completed and card moved to done",
      metadata: %{"stage" => "run_completed", "totalRunMs" => 573_649}
    })

    run =
      TraceReader.list_runs()
      |> Enum.find(&(&1.run_id == run_id))

    assert run
    assert run.status == "done"
    assert run.ended_at == "2026-03-04T21:36:11Z"
    assert run.duration_ms == 573_000
  end
end
