defmodule Crucible.AgentJobManager do
  @moduledoc """
  Manages async agent job lifecycle: launch → running → completed/failed/cancelled.

  Jobs are Postgres-backed (not in-memory like DeepAgents). Spawns work via
  DynamicSupervisor, updates DB on state transitions. Phases can use this
  as a tool to launch long-running subtasks.

  ## API Surface

  - `launch/1` — create and start a job
  - `get/1` — retrieve job status + result
  - `update/2` — update config (only while pending)
  - `cancel/1` — cancel a running job
  """

  require Logger

  alias Crucible.{Events, Repo}
  alias Crucible.{AuditLog}
  alias Crucible.Schema.AgentJob
  alias Crucible.TaskTool
  alias Crucible.Types.{Phase, Run}

  import Ecto.Query

  @doc "Launch a new agent job."
  @spec launch(map()) :: {:ok, AgentJob.t()} | {:error, term()}
  def launch(params) do
    attrs = %{
      run_id: params["run_id"],
      parent_phase: params["parent_phase"],
      config: params["config"] || %{},
      status: "pending",
      launched_at: DateTime.utc_now()
    }

    changeset = AgentJob.changeset(%AgentJob{}, attrs)

    case Repo.insert(changeset) do
      {:ok, job} ->
        # Start execution asynchronously
        Task.Supervisor.start_child(
          Crucible.TaskSupervisor,
          fn -> execute_job(job) end
        )

        Logger.info("AgentJobManager: launched job #{job.id} for run #{job.run_id}")
        AuditLog.log("agent_job", job.id, "created", %{run_id: job.run_id})
        Phoenix.PubSub.broadcast(Crucible.PubSub, "agent_jobs", {:agent_job_launched, job.id})
        {:ok, job}

      {:error, changeset} ->
        {:error, {:validation_failed, changeset}}
    end
  end

  @doc "Get a job by ID."
  @spec get(String.t()) :: {:ok, AgentJob.t()} | {:error, :not_found}
  def get(job_id) do
    case Repo.get(AgentJob, job_id) do
      nil -> {:error, :not_found}
      job -> {:ok, job}
    end
  end

  @doc "Update a pending job's config."
  @spec update(String.t(), map()) :: {:ok, AgentJob.t()} | {:error, term()}
  def update(job_id, attrs) do
    case Repo.get(AgentJob, job_id) do
      nil ->
        {:error, :not_found}

      %{status: "pending"} = job ->
        job
        |> AgentJob.changeset(Map.take(attrs, ["config"]))
        |> Repo.update()

      _job ->
        {:error, :not_pending}
    end
  end

  @doc "Cancel a running or pending job."
  @spec cancel(String.t()) :: {:ok, AgentJob.t()} | {:error, term()}
  def cancel(job_id) do
    case Repo.get(AgentJob, job_id) do
      nil ->
        {:error, :not_found}

      %{status: status} = job when status in ["pending", "running"] ->
        result =
          job
          |> AgentJob.changeset(%{status: "cancelled", completed_at: DateTime.utc_now()})
          |> Repo.update()

        AuditLog.log("agent_job", job_id, "cancelled")
        Phoenix.PubSub.broadcast(Crucible.PubSub, "agent_jobs", {:agent_job_cancelled, job_id})
        result

      _job ->
        {:error, :already_terminal}
    end
  end

  @doc "List jobs, optionally filtered."
  @spec list(keyword()) :: [AgentJob.t()]
  def list(opts \\ []) do
    query = from(j in AgentJob, order_by: [desc: j.inserted_at])

    query =
      case Keyword.get(opts, :run_id) do
        nil -> query
        run_id -> where(query, [j], j.run_id == ^run_id)
      end

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [j], j.status == ^status)
      end

    Repo.all(query)
  rescue
    _ -> []
  end

  # --- Private ---

  defp execute_job(job) do
    # Mark as running
    job
    |> AgentJob.changeset(%{status: "running"})
    |> Repo.update()

    config = if is_map(job.config) and not is_struct(job.config), do: job.config, else: %{}
    task_description = config["task"] || config["prompt"] || "Agent job #{job.id}"

    # Build a minimal run for TaskTool
    parent_run = %Run{
      id: job.run_id || "job-#{job.id}",
      workflow_type: "agent_job",
      task_description: task_description,
      budget_usd: config["budget_usd"] || 5.0,
      workspace_path: config["workspace_path"]
    }

    parent_phase = %Phase{
      id: job.parent_phase || "job-phase",
      name: "Agent Job",
      type: :session,
      phase_index: 0
    }

    task_config = %{
      "task" => task_description,
      "name" => config["name"] || "Job #{job.id}",
      "mode" => "sync",
      "timeout_ms" => config["timeout_ms"] || 300_000
    }

    case TaskTool.spawn_child(parent_run, parent_phase, task_config) do
      {:ok, result} ->
        result_map = if is_map(result), do: result, else: %{"value" => inspect(result)}

        job
        |> AgentJob.changeset(%{
          status: "completed",
          result: result_map,
          completed_at: DateTime.utc_now()
        })
        |> Repo.update()

        Events.broadcast_run_event(job.run_id || "", :agent_job_completed, %{
          job_id: job.id
        })

        AuditLog.log("agent_job", job.id, "completed", %{})
        Phoenix.PubSub.broadcast(Crucible.PubSub, "agent_jobs", {:agent_job_completed, job.id})

      {:error, reason} ->
        job
        |> AgentJob.changeset(%{
          status: "failed",
          error: inspect(reason),
          completed_at: DateTime.utc_now()
        })
        |> Repo.update()

        Events.broadcast_run_event(job.run_id || "", :agent_job_failed, %{
          job_id: job.id,
          reason: inspect(reason)
        })

        AuditLog.log("agent_job", job.id, "failed", %{error: inspect(reason)})
        Phoenix.PubSub.broadcast(Crucible.PubSub, "agent_jobs", {:agent_job_failed, job.id})
    end
  rescue
    e ->
      Logger.error("AgentJobManager: job #{job.id} crashed: #{Exception.message(e)}")

      job
      |> AgentJob.changeset(%{
        status: "failed",
        error: Exception.message(e),
        completed_at: DateTime.utc_now()
      })
      |> Repo.update()
  end
end
