defmodule Crucible.TypesTest do
  use ExUnit.Case, async: true

  alias Crucible.Types.{Run, Phase, WorkUnit, AgentUpdate}

  describe "Run struct" do
    test "has correct defaults" do
      run = %Run{id: "test", workflow_type: "ci"}
      assert run.status == :pending
      assert run.phases == []
      assert run.budget_usd == 50.0
      assert run.workspace_path == nil
    end
  end

  describe "Phase struct" do
    test "has correct defaults" do
      phase = %Phase{id: "p1", name: "Test"}
      assert phase.type == :session
      assert phase.status == :pending
      assert phase.max_retries == 2
      assert phase.retry_count == 0
      assert phase.timeout_ms == 600_000
      assert phase.depends_on == []
    end
  end

  describe "WorkUnit struct" do
    test "creates with path" do
      wu = %WorkUnit{path: "lib/foo.ex", role: "coder"}
      assert wu.path == "lib/foo.ex"
      assert wu.role == "coder"
      assert wu.description == nil
    end
  end

  describe "AgentUpdate struct" do
    test "creates with defaults" do
      update = %AgentUpdate{run_id: "r1", type: :progress}
      assert update.data == %{}
      assert update.phase_id == nil
    end
  end
end
