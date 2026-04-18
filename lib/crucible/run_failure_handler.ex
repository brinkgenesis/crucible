defmodule Crucible.RunFailureHandler do
  @moduledoc """
  Creates inbox items from failed workflow runs so operators can triage failures
  without watching logs. Called by RunServer when a run reaches terminal `:failed` status.
  """

  require Logger

  alias Crucible.Inbox
  alias Crucible.Repo
  alias Crucible.Schema.WorkflowRun

  @doc """
  Creates an inbox item summarising the failure for the given run_id.
  Returns `{:ok, inbox_item}` or `{:error, reason}`.
  """
  @spec create_inbox_item(String.t()) :: {:ok, map()} | {:error, any()}
  def create_inbox_item(run_id) do
    case Repo.get(WorkflowRun, run_id) do
      nil ->
        Logger.warning("RunFailureHandler: run #{run_id} not found in DB, skipping inbox item")
        {:error, :run_not_found}

      run ->
        attrs = %{
          source: "run_failure",
          source_id: "run:#{run_id}",
          title: "Run failed: #{run.workflow_name}",
          original_text: build_failure_text(run),
          summary: "Run #{run_id} failed (#{run.workflow_name})",
          author: "Orchestrator",
          ingested_at: DateTime.utc_now() |> DateTime.truncate(:second),
          metadata: %{
            run_id: run_id,
            workflow_name: run.workflow_name,
            status: run.status,
            retry_count: run.retry_count
          }
        }

        case Inbox.upsert_from_ingestion(attrs) do
          {:ok, item} ->
            Logger.info("RunFailureHandler: created inbox item #{item.id} for run #{run_id}")
            {:ok, item}

          {:error, reason} = err ->
            Logger.error(
              "RunFailureHandler: failed to create inbox item for run #{run_id}: #{inspect(reason)}"
            )

            err
        end
    end
  rescue
    e ->
      Logger.error(
        "RunFailureHandler: unexpected error for run #{run_id}: #{Exception.message(e)}"
      )

      {:error, :unexpected}
  end

  defp build_failure_text(run) do
    "Workflow run #{run.run_id} (#{run.workflow_name}) failed after " <>
      "#{run.retry_count || 0} retries. Task: #{String.slice(run.task_description || "", 0..200)}"
  end
end
