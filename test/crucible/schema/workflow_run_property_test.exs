defmodule Crucible.Schema.WorkflowRunPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Crucible.Schema.WorkflowRun
  import Crucible.Generators

  property "valid workflow_name + status always produces valid changeset" do
    check all(
            name <- workflow_name(),
            status <- run_status(),
            exec_type <- execution_type(),
            desc <- task_description()
          ) do
      cs =
        WorkflowRun.changeset(%WorkflowRun{run_id: Ecto.UUID.generate()}, %{
          workflow_name: name,
          status: status,
          execution_type: exec_type,
          task_description: desc
        })

      assert cs.valid?
    end
  end

  property "invalid status is rejected" do
    check all(status <- invalid_run_status()) do
      cs =
        WorkflowRun.changeset(%WorkflowRun{run_id: Ecto.UUID.generate()}, %{
          workflow_name: "test",
          status: status,
          execution_type: "subscription",
          task_description: "test"
        })

      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :status)
    end
  end

  property "missing required fields produces invalid changeset" do
    check all(field <- member_of([:workflow_name, :task_description])) do
      attrs =
        %{
          workflow_name: "test",
          status: "pending",
          execution_type: "subscription",
          task_description: "test"
        }
        |> Map.delete(field)

      cs = WorkflowRun.changeset(%WorkflowRun{run_id: Ecto.UUID.generate()}, attrs)
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, field)
    end
  end
end
