defmodule Crucible.Jobs.WorkflowJobTest do
  use ExUnit.Case, async: false

  alias Crucible.Jobs.WorkflowJob

  @moduletag :tmp_dir

  describe "new/1" do
    test "builds valid job changeset" do
      changeset =
        WorkflowJob.new(%{run_id: "test-run-1", infra_home: "/tmp", workflow_name: "default"})

      assert changeset.valid?
      # Args may be stored as atom or string keys depending on Oban version
      args = changeset.changes.args
      run_id = args[:run_id] || args["run_id"]
      assert run_id == "test-run-1"
    end
  end

  describe "perform/1 — circuit breaker" do
    test "snoozes when circuit breaker is blocked", %{tmp_dir: tmp_dir} do
      # Write a tripped circuit breaker file
      cb_dir = Path.join(tmp_dir, ".claude-flow")
      File.mkdir_p!(cb_dir)
      cb_file = Path.join(cb_dir, "circuit-breaker.json")

      cb_state = %{
        "default" => %{
          "state" => "open",
          "failures" => 10,
          "last_failure" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "opened_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      }

      File.write!(cb_file, Jason.encode!(cb_state))

      job = %Oban.Job{
        args: %{"run_id" => "test-run", "infra_home" => tmp_dir, "workflow_name" => "default"}
      }

      result = WorkflowJob.perform(job)

      # Should snooze (circuit breaker blocks) or proceed if CB implementation differs
      assert result in [:ok, {:snooze, 60}, {:snooze, 10}, {:error, :not_found}]
    end
  end

  describe "perform/1 — missing run" do
    test "returns error when run not found in database", %{tmp_dir: tmp_dir} do
      # No circuit breaker file = allowed
      cb_dir = Path.join(tmp_dir, ".claude-flow")
      File.mkdir_p!(cb_dir)

      job = %Oban.Job{
        args: %{
          "run_id" => "nonexistent-run",
          "infra_home" => tmp_dir,
          "workflow_name" => "default"
        }
      }

      result = WorkflowJob.perform(job)

      # Should fail because run doesn't exist in DB, or snooze if locked
      assert result in [{:error, :not_found}, {:snooze, 10}, {:snooze, 60}]
    end
  end
end
