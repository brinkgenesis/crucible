defmodule Crucible.WorkflowPersistence do
  @moduledoc """
  Persists workflow runs to the database via Ecto.
  Syncs the in-memory Run struct to the `workflow_runs` DB table.
  Maps to `upsertRun` in lib/db/workflow-runs.ts.
  """

  require Logger

  import Ecto.Query

  alias Crucible.{AuditLog, Repo}
  alias Crucible.Schema.WorkflowRun
  alias Crucible.Types.Run

  @doc "Look up the kanban card_id associated with a workflow run."
  @spec get_card_id(String.t()) :: String.t() | nil
  def get_card_id(run_id) when is_binary(run_id) do
    Repo.one(from r in WorkflowRun, where: r.run_id == ^run_id, select: r.card_id)
  rescue
    _ -> nil
  end

  @doc "Upsert a Run struct into the database."
  @spec upsert_run(Run.t()) :: {:ok, WorkflowRun.t()} | {:error, term()}
  def upsert_run(%Run{} = run) do
    attrs = %{
      run_id: run.id,
      workflow_name: run.workflow_type,
      workspace_path: run.workspace_path,
      task_description: run.task_description || run.plan_summary || "",
      version: run.version,
      status: to_string(run.status),
      execution_type: run.execution_type,
      phases:
        Enum.map(run.phases, fn phase ->
          %{
            id: phase.id,
            name: phase.name,
            type: to_string(phase.type),
            status: to_string(phase.status),
            phase_index: phase.phase_index,
            session_id: phase.session_id,
            retry_count: phase.retry_count || 0,
            timeout_ms: phase.timeout_ms || 600_000,
            depends_on: phase.depends_on || [],
            agents: serialize_agents(phase.agents || []),
            create_branch: phase.create_branch || false
          }
        end),
      plan_note: run.plan_note,
      plan_summary: run.plan_summary,
      complexity: run.complexity,
      base_commit: run.base_commit,
      session_resume_chain: run.session_resume_chain,
      last_transition_key: run.last_transition_key,
      retry_count: run.retry_count,
      max_retries: run.max_retries,
      policy: serialize_policy(run.policy),
      pull_request: serialize_pull_request(run.pull_request),
      card_id: run.card_id,
      client_id: run.client_id
    }

    case Repo.get(WorkflowRun, run.id) do
      nil ->
        result =
          %WorkflowRun{run_id: run.id}
          |> WorkflowRun.changeset(attrs)
          |> Repo.insert()

        with {:ok, _} <- result do
          AuditLog.log("workflow_run", run.id, "created", %{workflow: run.workflow_type})
        end

        result

      existing ->
        existing
        |> WorkflowRun.changeset(attrs)
        |> Repo.update()
    end
  rescue
    e ->
      Logger.warning("WorkflowPersistence: upsert_run failed: #{inspect(e)}")
      {:error, e}
  end

  @doc "Load a Run from the database by ID."
  @spec load_run(String.t()) :: {:ok, Run.t()} | {:error, :not_found}
  def load_run(run_id) do
    case Repo.get(WorkflowRun, run_id) do
      nil ->
        {:error, :not_found}

      %WorkflowRun{} = wr ->
        {:ok, deserialize_run(wr)}
    end
  rescue
    e ->
      Logger.warning("WorkflowPersistence: load_run failed: #{inspect(e)}")
      {:error, e}
  end

  @doc "Update just the status of a run in the database."
  @spec update_status(String.t(), String.t()) :: :ok | {:error, term()}
  def update_status(run_id, status) do
    case Repo.get(WorkflowRun, run_id) do
      nil ->
        {:error, :not_found}

      existing ->
        existing
        |> WorkflowRun.changeset(%{status: status})
        |> Repo.update()
        |> case do
          {:ok, _} ->
            AuditLog.log("workflow_run", run_id, "status_changed", %{status: status})
            :ok

          err ->
            err
        end
    end
  rescue
    e -> {:error, e}
  end

  # --- Private ---

  defp serialize_agents(agents) when is_list(agents) do
    Enum.map(agents, fn
      a when is_binary(a) -> a
      %{role: role} -> role
      a when is_map(a) -> Map.get(a, "role", inspect(a))
      a -> to_string(a)
    end)
  end

  defp serialize_agents(_), do: []

  defp serialize_policy(nil), do: nil

  defp serialize_policy(%{} = p) do
    %{
      policy_id: p[:policy_id] || p.policy_id,
      variant: p[:variant] || p.variant,
      canary: p[:canary] || false,
      timings: p[:timings] || p.timings
    }
  end

  defp serialize_pull_request(nil), do: nil

  defp serialize_pull_request(%{} = pr) do
    %{
      branch_name: pr[:branch_name] || pr.branch_name,
      number: pr[:number] || pr.number,
      url: pr[:url] || pr.url
    }
  end

  defp deserialize_policy(nil), do: nil

  defp deserialize_policy(%{} = p) do
    %{
      policy_id: p.policy_id,
      variant: p.variant,
      canary: p.canary || false,
      timings: p.timings
    }
  end

  defp deserialize_pull_request(nil), do: nil

  defp deserialize_pull_request(%{} = pr) do
    %{
      branch_name: pr.branch_name,
      number: pr.number,
      url: pr.url
    }
  end

  defp deserialize_run(%WorkflowRun{} = wr) do
    alias Crucible.Types.Phase

    phases =
      (wr.phases || [])
      |> Enum.map(fn p ->
        %Phase{
          id: p.id || "",
          name: p.name || "",
          type: parse_type(p.type || "session"),
          status: parse_status(p.status || "pending"),
          phase_index: p.phase_index || 0,
          session_id: p.session_id,
          retry_count: p.retry_count || 0,
          timeout_ms: p.timeout_ms || 600_000
        }
      end)

    chain = wr.session_resume_chain

    %Run{
      id: wr.run_id,
      workflow_type: wr.workflow_name,
      workspace_path: wr.workspace_path,
      status: parse_status(wr.status),
      phases: phases,
      plan_note: wr.plan_note,
      plan_summary: wr.plan_summary,
      task_description: wr.task_description,
      client_id: wr.client_id,
      card_id: wr.card_id,
      version: wr.version || 0,
      complexity: wr.complexity,
      base_commit: wr.base_commit,
      execution_type: wr.execution_type || "subscription",
      session_resume_chain: chain,
      last_transition_key: wr.last_transition_key,
      retry_count: wr.retry_count || 0,
      max_retries: wr.max_retries || 3,
      policy: deserialize_policy(wr.policy),
      pull_request: deserialize_pull_request(wr.pull_request),
      started_at: wr.created_at,
      completed_at: nil
    }
  end

  defp parse_type("session"), do: :session
  defp parse_type("team"), do: :team
  defp parse_type("review_gate"), do: :review_gate
  defp parse_type("pr_shepherd"), do: :pr_shepherd
  defp parse_type("preflight"), do: :preflight
  defp parse_type(_), do: :session

  defp parse_status("pending"), do: :pending
  defp parse_status("running"), do: :running
  defp parse_status("completed"), do: :completed
  defp parse_status("done"), do: :done
  defp parse_status("review"), do: :review
  defp parse_status("failed"), do: :failed
  defp parse_status("cancelled"), do: :cancelled
  defp parse_status("orphaned"), do: :orphaned
  defp parse_status("budget_paused"), do: :budget_paused
  defp parse_status(_), do: :pending
end
