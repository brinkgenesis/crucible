defmodule Crucible.SessionResumptionTest do
  use ExUnit.Case, async: true

  alias Crucible.SessionResumption
  alias Crucible.Types.{Run, Phase}

  describe "resolve_session_id/2" do
    test "returns nil for non-session-like phases" do
      run = %Run{id: "run-1", workflow_type: "test", phases: []}
      phase = %Phase{id: "p-0", name: "Build", type: :team, phase_index: 1}
      assert SessionResumption.resolve_session_id(run, phase) == nil
    end

    test "returns nil for non-session-like :api phase" do
      run = %Run{id: "run-1", workflow_type: "test", phases: []}
      phase = %Phase{id: "p-0", name: "API", type: :api, phase_index: 1}
      assert SessionResumption.resolve_session_id(run, phase) == nil
    end

    test "returns nil for non-session-like :review_gate phase" do
      run = %Run{id: "run-1", workflow_type: "test", phases: []}
      phase = %Phase{id: "p-0", name: "Review", type: :review_gate, phase_index: 1}
      assert SessionResumption.resolve_session_id(run, phase) == nil
    end

    test "returns nil when no prior phases exist" do
      run = %Run{id: "run-1", workflow_type: "test", phases: []}
      phase = %Phase{id: "p-0", name: "Code", type: :session, phase_index: 0}
      assert SessionResumption.resolve_session_id(run, phase) == nil
    end

    test "resolves from session_resume_chain" do
      run = %Run{
        id: "run-1",
        workflow_type: "test",
        phases: [],
        session_resume_chain: ["sess-abc", nil, "sess-def"]
      }

      phase = %Phase{id: "p-3", name: "Code", type: :session, phase_index: 3}
      assert SessionResumption.resolve_session_id(run, phase) == "sess-def"
    end

    test "walks chain in reverse to find nearest" do
      run = %Run{
        id: "run-1",
        workflow_type: "test",
        phases: [],
        session_resume_chain: ["sess-0", nil, "sess-2", nil]
      }

      phase = %Phase{id: "p-4", name: "Code", type: :session, phase_index: 4}
      assert SessionResumption.resolve_session_id(run, phase) == "sess-2"
    end

    test "falls back to completed phases when no chain" do
      phases = [
        %Phase{
          id: "p-0",
          name: "Plan",
          type: :session,
          status: :completed,
          session_id: "sess-plan",
          phase_index: 0
        },
        %Phase{
          id: "p-1",
          name: "Code",
          type: :session,
          status: :completed,
          session_id: "sess-code",
          phase_index: 1
        }
      ]

      run = %Run{id: "run-1", workflow_type: "test", phases: phases}
      phase = %Phase{id: "p-2", name: "Review", type: :session, phase_index: 2}

      assert SessionResumption.resolve_session_id(run, phase) == "sess-code"
    end

    test "skips non-session and non-completed phases" do
      phases = [
        %Phase{
          id: "p-0",
          name: "Plan",
          type: :session,
          status: :completed,
          session_id: "sess-0",
          phase_index: 0
        },
        %Phase{
          id: "p-1",
          name: "Team",
          type: :team,
          status: :completed,
          session_id: nil,
          phase_index: 1
        },
        %Phase{
          id: "p-2",
          name: "Review",
          type: :session,
          status: :failed,
          session_id: "sess-2",
          phase_index: 2
        }
      ]

      run = %Run{id: "run-1", workflow_type: "test", phases: phases}
      phase = %Phase{id: "p-3", name: "Final", type: :session, phase_index: 3}

      # Should skip p-2 (failed) and p-1 (team), find p-0
      assert SessionResumption.resolve_session_id(run, phase) == "sess-0"
    end

    test "works for pr_shepherd phase type" do
      phases = [
        %Phase{
          id: "p-0",
          name: "Code",
          type: :session,
          status: :completed,
          session_id: "sess-code",
          phase_index: 0
        }
      ]

      run = %Run{id: "run-1", workflow_type: "test", phases: phases}
      phase = %Phase{id: "p-1", name: "PR", type: :pr_shepherd, phase_index: 1}

      assert SessionResumption.resolve_session_id(run, phase) == "sess-code"
    end

    test "works for preflight phase type" do
      phases = [
        %Phase{
          id: "p-0",
          name: "Code",
          type: :session,
          status: :completed,
          session_id: "sess-code",
          phase_index: 0
        }
      ]

      run = %Run{id: "run-1", workflow_type: "test", phases: phases}
      phase = %Phase{id: "p-1", name: "Preflight", type: :preflight, phase_index: 1}

      assert SessionResumption.resolve_session_id(run, phase) == "sess-code"
    end

    test "returns nil when all prior sessions lack session_id" do
      phases = [
        %Phase{
          id: "p-0",
          name: "Plan",
          type: :session,
          status: :completed,
          session_id: nil,
          phase_index: 0
        }
      ]

      run = %Run{id: "run-1", workflow_type: "test", phases: phases}
      phase = %Phase{id: "p-1", name: "Code", type: :session, phase_index: 1}

      assert SessionResumption.resolve_session_id(run, phase) == nil
    end
  end
end
