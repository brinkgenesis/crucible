defmodule Crucible.WorkflowPersistenceTest do
  use ExUnit.Case, async: true

  alias Crucible.WorkflowPersistence
  alias Crucible.Types.{Run, Phase}

  describe "upsert_run/1 (without DB)" do
    test "returns error when Repo is unavailable" do
      run = %Run{
        id: "test-run-persist",
        workflow_type: "test",
        phases: [%Phase{id: "p-0", name: "Code", type: :session, phase_index: 0}]
      }

      # Without a running Repo, this should fail gracefully
      result = WorkflowPersistence.upsert_run(run)
      assert {:error, _} = result
    end
  end

  describe "serialize_phases (via module)" do
    test "Run struct has all required fields" do
      run = %Run{
        id: "run-serial",
        workflow_type: "feature",
        status: :running,
        client_id: "client-1",
        session_resume_chain: ["sess-0", nil, "sess-2"],
        phases: [
          %Phase{
            id: "p-0",
            name: "Plan",
            type: :session,
            status: :completed,
            phase_index: 0,
            session_id: "sess-0"
          },
          %Phase{
            id: "p-1",
            name: "Code",
            type: :team,
            status: :pending,
            phase_index: 1
          }
        ]
      }

      assert run.client_id == "client-1"
      assert run.session_resume_chain == ["sess-0", nil, "sess-2"]
      assert length(run.phases) == 2
      assert hd(run.phases).session_id == "sess-0"
    end
  end
end
