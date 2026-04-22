defmodule Crucible.AgentJobManagerTest do
  use Crucible.DataCase, async: false

  alias Crucible.AgentJobManager
  alias Crucible.Schema.AgentJob

  describe "launch/1" do
    test "creates a pending job and returns it" do
      params = %{
        "run_id" => "test-run-1",
        "parent_phase" => "phase-0",
        "config" => %{"task" => "do something", "budget_usd" => 1.0}
      }

      assert {:ok, %AgentJob{} = job} = AgentJobManager.launch(params)
      assert job.run_id == "test-run-1"
      assert job.parent_phase == "phase-0"
      assert job.config["task"] == "do something"
      assert job.status == "pending"
      assert job.launched_at != nil
      assert job.id != nil
    end

    test "creates job with default empty config" do
      params = %{"run_id" => "test-run-2"}

      assert {:ok, %AgentJob{} = job} = AgentJobManager.launch(params)
      assert job.config == %{}
    end

    test "creates job with nil run_id" do
      params = %{"config" => %{"task" => "orphan job"}}

      assert {:ok, %AgentJob{} = job} = AgentJobManager.launch(params)
      assert job.run_id == nil
    end
  end

  describe "get/1" do
    test "returns job by ID" do
      {:ok, created} = AgentJobManager.launch(%{"run_id" => "get-test"})
      assert {:ok, fetched} = AgentJobManager.get(created.id)
      assert fetched.id == created.id
      assert fetched.run_id == "get-test"
    end

    test "returns :not_found for missing job" do
      assert {:error, :not_found} = AgentJobManager.get(Ecto.UUID.generate())
    end
  end

  describe "update/2" do
    test "updates config on pending job" do
      # Insert directly to avoid background execute_job race
      job =
        %AgentJob{}
        |> AgentJob.changeset(%{
          run_id: "upd-test",
          config: %{"a" => 1},
          status: "pending",
          launched_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      assert {:ok, updated} = AgentJobManager.update(job.id, %{"config" => %{"a" => 2, "b" => 3}})
      assert updated.config["a"] == 2
      assert updated.config["b"] == 3
    end

    test "rejects update on non-pending job" do
      job =
        %AgentJob{}
        |> AgentJob.changeset(%{
          run_id: "upd-reject",
          status: "running",
          launched_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      assert {:error, :not_pending} = AgentJobManager.update(job.id, %{"config" => %{}})
    end

    test "returns :not_found for missing job" do
      assert {:error, :not_found} = AgentJobManager.update(Ecto.UUID.generate(), %{})
    end
  end

  describe "cancel/1" do
    @tag :skip
    test "cancels a pending job" do
      {:ok, job} = AgentJobManager.launch(%{"run_id" => "cancel-pend"})

      assert {:ok, cancelled} = AgentJobManager.cancel(job.id)
      assert cancelled.status == "cancelled"
      assert cancelled.completed_at != nil
    end

    @tag :skip
    test "cancels a running job" do
      {:ok, job} = AgentJobManager.launch(%{"run_id" => "cancel-run"})

      job
      |> AgentJob.changeset(%{status: "running"})
      |> Repo.update!()

      assert {:ok, cancelled} = AgentJobManager.cancel(job.id)
      assert cancelled.status == "cancelled"
    end

    test "rejects cancel on completed job" do
      job =
        %AgentJob{}
        |> AgentJob.changeset(%{
          run_id: "cancel-done",
          status: "completed",
          launched_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      assert {:error, :already_terminal} = AgentJobManager.cancel(job.id)
    end

    test "rejects cancel on failed job" do
      job =
        %AgentJob{}
        |> AgentJob.changeset(%{
          run_id: "cancel-fail",
          status: "failed",
          launched_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      assert {:error, :already_terminal} = AgentJobManager.cancel(job.id)
    end

    test "returns :not_found for missing job" do
      assert {:error, :not_found} = AgentJobManager.cancel(Ecto.UUID.generate())
    end
  end

  describe "list/1" do
    test "returns all jobs" do
      {:ok, j1} = AgentJobManager.launch(%{"run_id" => "list-r1"})
      {:ok, j2} = AgentJobManager.launch(%{"run_id" => "list-r2"})

      jobs = AgentJobManager.list()
      job_ids = Enum.map(jobs, & &1.id)
      assert j1.id in job_ids
      assert j2.id in job_ids
    end

    test "filters by run_id" do
      {:ok, _} = AgentJobManager.launch(%{"run_id" => "filter-run-A"})
      {:ok, _} = AgentJobManager.launch(%{"run_id" => "filter-run-B"})

      jobs = AgentJobManager.list(run_id: "filter-run-A")
      assert Enum.all?(jobs, &(&1.run_id == "filter-run-A"))
    end

    test "filters by status" do
      {:ok, job} = AgentJobManager.launch(%{"run_id" => "filter-status"})

      job
      |> AgentJob.changeset(%{status: "completed", completed_at: DateTime.utc_now()})
      |> Repo.update!()

      completed = AgentJobManager.list(status: "completed")
      assert Enum.all?(completed, &(&1.status == "completed"))
    end

    test "returns empty list when no matches" do
      jobs = AgentJobManager.list(run_id: "nonexistent-run-#{System.unique_integer()}")
      assert jobs == []
    end
  end

  describe "AgentJob schema" do
    test "validates status inclusion" do
      changeset = AgentJob.changeset(%AgentJob{}, %{status: "invalid_status"})
      refute changeset.valid?
    end

    test "accepts valid statuses" do
      for status <- ~w(pending running completed failed cancelled) do
        changeset = AgentJob.changeset(%AgentJob{}, %{status: status})
        assert changeset.valid?, "Expected status '#{status}' to be valid"
      end
    end
  end
end
