defmodule Crucible.PhaseRunner do
  @moduledoc """
  Executes a single phase within a workflow run.
  Delegates to the appropriate adapter based on phase type.
  Handles sentinel pre-checks, review-gate verdicts, team fallback, and loop detection.

  Implementation is split across focused submodules:
  * `PhaseRunner.Executor`  — budget gate, adapter dispatch, validation, sentinel hygiene
  * `PhaseRunner.Detectors` — loop-check timer and stuck-task detector lifecycle
  * `PhaseRunner.Telemetry` — trace emission, JSONL persistence, token metrics
  """

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  alias Crucible.Types.{Run, Phase}
  alias Crucible.Claude.Protocol
  alias Crucible.PhaseRunner.{Detectors, Executor}

  @doc "Execute a phase, selecting the appropriate adapter."
  @spec execute(Run.t(), Phase.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(%Run{} = run, %Phase{} = phase, opts \\ []) do
    Tracer.with_span "orchestrator.phase.execute" do
      Tracer.set_attributes([
        {"phase.type", to_string(phase.type)},
        {"phase.id", phase.id},
        {"run.id", run.id}
      ])

      Logger.info("PhaseRunner: executing phase #{phase.id} (#{phase.type}) for run #{run.id}")
      runs_dir = Keyword.get(opts, :runs_dir, ".claude-flow/runs")

      sentinel_path = Protocol.sentinel_path(runs_dir, run.id, phase.id)
      base_commit = Keyword.get(opts, :base_commit)

      case Protocol.read_sentinel(sentinel_path, base_commit) do
        {:ok, sentinel_data} ->
          if phase.type == :pr_shepherd do
            Executor.validate_pr_shepherd(
              run,
              phase,
              sentinel_data,
              sentinel_path,
              runs_dir,
              opts
            )
          else
            Logger.info("PhaseRunner: phase #{phase.id} already complete (sentinel)")
            {:ok, %{status: :skipped, sentinel: sentinel_data}}
          end

        :stale ->
          Logger.warning("PhaseRunner: stale sentinel for phase #{phase.id}, re-executing")

          case Protocol.remove_sentinel(sentinel_path) do
            :ok ->
              Executor.do_execute(run, phase, runs_dir, opts)

            {:error, reason} ->
              Logger.error(
                "PhaseRunner: cannot remove stale sentinel #{sentinel_path}: #{inspect(reason)}, aborting"
              )

              {:error, {:stale_sentinel_removal_failed, reason}}
          end

        :not_found ->
          if skip_planned?(run, phase) do
            Protocol.write_sentinel(sentinel_path)
            {:ok, %{status: :skipped_planned}}
          else
            Executor.do_execute(run, phase, runs_dir, opts)
          end
      end
    end
  end

  @doc false
  @spec handle_loop_check(String.t(), String.t()) :: :ok | {:halt, map()}
  def handle_loop_check(run_id, phase_id) do
    Detectors.handle_loop_check(run_id, phase_id)
  end

  # --- Private ---

  defp skip_planned?(%Run{plan_note: note}, %Phase{type: :session})
       when is_binary(note) and note != "" do
    false
  end

  defp skip_planned?(_run, _phase), do: false
end
