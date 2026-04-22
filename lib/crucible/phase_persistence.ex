defmodule Crucible.PhasePersistence do
  @moduledoc """
  Persists phase execution state to Postgres so that crashed runs
  can be detected and recovered on node restart.
  """

  require Logger

  alias Crucible.Repo
  alias Crucible.Schema.WorkflowRun

  import Ecto.Query

  @doc "Record that a phase has started executing on this node."
  @spec record_phase_start(String.t(), non_neg_integer()) :: :ok
  def record_phase_start(run_id, phase_index) do
    update_phase_state(run_id, %{
      current_phase_index: phase_index,
      current_phase_status: "running",
      active_node: to_string(node()),
      status: "running"
    })
  end

  @doc "Record that a phase completed successfully."
  @spec record_phase_complete(String.t(), non_neg_integer()) :: :ok
  def record_phase_complete(run_id, phase_index) do
    update_phase_state(run_id, %{
      current_phase_index: phase_index,
      current_phase_status: "completed"
    })
  end

  @doc "Record that a phase failed."
  @spec record_phase_failed(String.t(), non_neg_integer(), String.t()) :: :ok
  def record_phase_failed(run_id, phase_index, reason) do
    update_phase_state(run_id, %{
      current_phase_index: phase_index,
      current_phase_status: "failed:#{String.slice(reason, 0, 200)}"
    })
  end

  @doc "Record that the entire run completed."
  @spec record_run_complete(String.t()) :: :ok
  def record_run_complete(run_id) do
    update_phase_state(run_id, %{
      status: "completed",
      current_phase_status: "completed",
      active_node: nil
    })
  end

  @doc "Record that the entire run failed."
  @spec record_run_failed(String.t()) :: :ok
  def record_run_failed(run_id) do
    update_phase_state(run_id, %{
      status: "failed",
      active_node: nil
    })
  end

  @doc """
  Find runs that were active on a crashed node.
  Returns runs where active_node matches but status is still "running".
  """
  @spec find_crashed_runs(String.t()) :: [WorkflowRun.t()]
  def find_crashed_runs(node_name) do
    from(r in WorkflowRun,
      where: r.active_node == ^node_name and r.status == "running"
    )
    |> Repo.all()
  rescue
    _ -> []
  end

  @doc "Mark crashed runs as failed so they can be retried by the orchestrator."
  @spec mark_crashed_runs(String.t()) :: non_neg_integer()
  def mark_crashed_runs(node_name) do
    {count, _} =
      from(r in WorkflowRun,
        where: r.active_node == ^node_name and r.status == "running"
      )
      |> Repo.update_all(
        set: [
          current_phase_status: "crashed",
          active_node: nil
        ]
      )

    if count > 0 do
      Logger.warning("PhasePersistence: marked #{count} crashed runs from node #{node_name}")
    end

    count
  rescue
    e ->
      Logger.warning("PhasePersistence: failed to mark crashed runs: #{Exception.message(e)}")
      0
  end

  # ---

  defp update_phase_state(run_id, attrs) do
    case Repo.get(WorkflowRun, run_id) do
      nil ->
        Logger.debug("PhasePersistence: run #{run_id} not in DB, skipping phase state update")
        :ok

      run ->
        run
        |> Ecto.Changeset.change(attrs)
        |> Repo.update()
        |> case do
          {:ok, _} ->
            :ok

          {:error, changeset} ->
            Logger.warning(
              "PhasePersistence: update failed for #{run_id}: #{inspect(changeset.errors)}"
            )

            :ok
        end
    end
  rescue
    e ->
      Logger.warning("PhasePersistence: DB error for #{run_id}: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ ->
      Logger.warning("PhasePersistence: DB unavailable for #{run_id}")
      :ok
  end
end
