defmodule Crucible.Jobs.WorkflowJob do
  @moduledoc """
  Oban worker for async workflow execution (DB-backed path).

  ## Execution Path: Oban Job Queue (DB-Backed)

  This worker is enqueued via `enqueue/2` and executed by Oban. It:
  1. Checks the file-based circuit breaker (`Crucible.CircuitBreaker`)
  2. Acquires an executor lock (`ExecutorLock`) to prevent concurrent runs
  3. Loads the run from DB via `WorkflowPersistence`
  4. Executes phases sequentially via `PhaseRunner.execute/3`
  5. Updates run status in DB on completion/failure/budget_paused

  Uses Oban's built-in retry (max_attempts: 3) and uniqueness (5min window).
  Budget-paused runs snooze for 5 minutes instead of failing.

  ## Alternative Path: GenServer Poll/Dispatch (In-Memory)

  See `Crucible.Orchestrator` for the in-memory GenServer execution path.
  Both paths converge at `PhaseRunner.execute/3` for actual phase execution.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 300, fields: [:args], keys: [:run_id]]

  require Logger

  alias Crucible.{
    CircuitBreaker,
    ExecutorLock,
    PhaseRunner,
    SelfImprovement,
    WorkflowPersistence
  }

  alias Crucible.Types.Run

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id} = args}) do
    infra_home = Map.get(args, "infra_home", File.cwd!())

    # Circuit breaker gate
    workflow_name = Map.get(args, "workflow_name", "default")

    case CircuitBreaker.check(infra_home, workflow_name) do
      {:blocked, reason} ->
        Logger.warning("WorkflowJob: #{reason}")
        {:snooze, 60}

      {:ok, :allowed} ->
        case ExecutorLock.acquire(infra_home) do
          {:ok, _lock} ->
            try do
              result = execute_run(run_id, infra_home)
              success? = match?(:ok, result)
              CircuitBreaker.record(infra_home, workflow_name, success?)
              result
            after
              ExecutorLock.release(infra_home)
            end

          {:error, :locked} ->
            Logger.warning("WorkflowJob: executor locked, snoozing run #{run_id}")
            {:snooze, 10}
        end
    end
  end

  @doc "Enqueue a workflow run for async execution."
  @spec enqueue(String.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(run_id, opts \\ []) do
    infra_home = Keyword.get(opts, :infra_home, File.cwd!())
    workflow_name = Keyword.get(opts, :workflow_name, "default")

    %{run_id: run_id, infra_home: infra_home, workflow_name: workflow_name}
    |> new()
    |> Oban.insert()
  end

  # --- Private ---

  defp execute_run(run_id, infra_home) do
    case WorkflowPersistence.load_run(run_id) do
      {:ok, %Run{} = run} ->
        WorkflowPersistence.update_status(run_id, "running")
        execute_phases(run, infra_home)

      {:error, _} ->
        Logger.error("WorkflowJob: run #{run_id} not found in database")
        {:error, :not_found}
    end
  end

  defp execute_phases(%Run{phases: phases} = run, infra_home) do
    result =
      phases
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {phase, _idx}, _acc ->
        # Check dependencies are met
        if dependencies_met?(phase, run.phases) do
          case PhaseRunner.execute(run, phase, infra_home: infra_home) do
            {:ok, _} ->
              {:cont, :ok}

            {:error, reason} ->
              Logger.error("WorkflowJob: phase #{phase.id} failed: #{inspect(reason)}")
              {:halt, {:error, reason}}
          end
        else
          Logger.warning("WorkflowJob: phase #{phase.id} dependencies not met, skipping")
          {:cont, :ok}
        end
      end)

    case result do
      :ok ->
        WorkflowPersistence.update_status(run.id, "completed")
        trigger_self_improvement(run.id)
        :ok

      {:error, :budget_paused} ->
        WorkflowPersistence.update_status(run.id, "budget_paused")
        {:snooze, 300}

      {:error, _} = err ->
        WorkflowPersistence.update_status(run.id, "failed")
        trigger_self_improvement(run.id)
        err
    end
  end

  defp trigger_self_improvement(run_id) do
    SelfImprovement.trigger(run_id)
  rescue
    _ -> :ok
  end

  defp dependencies_met?(%{depends_on: []}, _phases), do: true
  defp dependencies_met?(%{depends_on: nil}, _phases), do: true

  defp dependencies_met?(%{depends_on: deps}, phases) do
    Enum.all?(deps, fn dep_id ->
      case Enum.find(phases, &(&1.id == dep_id)) do
        %{status: :completed} -> true
        _ -> false
      end
    end)
  end
end
