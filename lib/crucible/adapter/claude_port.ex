defmodule Crucible.Adapter.ClaudePort do
  @moduledoc """
  Tmux-based adapter: spawns Claude CLI in a detached tmux session and
  injects prompts via bracketed paste. Matches the TypeScript predecessor.

  - Session phases: single interactive Claude session, polls for sentinel file
  - Team phases: interactive Claude with Agent Teams enabled, polls for team task completion
  """
  @behaviour Crucible.Adapter.Behaviour

  require Logger

  alias Crucible.Claude.Session
  alias Crucible.BudgetTracker

  @max_spawn_retries 3

  @impl true
  def execute_phase(run, phase, prompt, opts \\ []) do
    working_dir = run.workspace_path || Keyword.get(opts, :infra_home) || File.cwd!()
    runs_dir = Keyword.get(opts, :runs_dir, ".claude-flow/runs")

    session_opts = [
      run_id: run.id,
      phase_id: phase.id,
      timeout_ms: phase.timeout_ms,
      runs_dir: runs_dir,
      is_team: phase.type == :team,
      workflow_type: run.workflow_type,
      phase_index: phase.phase_index,
      client_id: run.client_id,
      validation_checks: Keyword.get(opts, :validation_checks, []),
      validation_timeout_ms: Keyword.get(opts, :validation_timeout_ms, 60_000)
    ]

    Logger.info(
      "ClaudePort: starting tmux session for run=#{run.id} phase=#{phase.id} (#{phase.type})"
    )

    execute_with_retry(run, phase, prompt, working_dir, session_opts, 0)
  end

  @impl true
  def cleanup_artifacts(_run, _phase), do: :ok

  # --- Private ---

  defp execute_with_retry(run, phase, prompt, working_dir, session_opts, attempt) do
    case Session.execute(prompt, working_dir, session_opts) do
      {:ok, result} ->
        if result.cost do
          BudgetTracker.record_cost(run.id, result.cost)
        end

        {:ok, result}

      {:error, reason} when attempt < @max_spawn_retries ->
        Logger.warning(
          "ClaudePort: #{inspect(reason)} for run=#{run.id} phase=#{phase.id}, retry #{attempt + 1}/#{@max_spawn_retries}"
        )

        Process.sleep(5_000 * (attempt + 1))
        execute_with_retry(run, phase, prompt, working_dir, session_opts, attempt + 1)

      {:error, :timeout} ->
        Logger.error("ClaudePort: timeout for run=#{run.id} phase=#{phase.id}")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("ClaudePort: failed for run=#{run.id} phase=#{phase.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
