defmodule Crucible.PhaseRunner.Executor do
  @moduledoc """
  Core execution logic for a single phase.

  Responsibilities:
  * Budget gate enforcement before any adapter call
  * Adapter selection (`adapter_for/1`)
  * Dispatching to `:review_gate` / `:team` / generic adapter paths
  * PR-shepherd DoD re-execution check
  * Post-execution validation via `ValidationRunner`
  * Sentinel hygiene (ensure sentinel written on success)
  * Telemetry: start/stop events, trace emission, metrics enrichment
  """

  require Logger

  alias Crucible.Types.{Run, Phase}
  alias Crucible.Adapter
  alias Crucible.Claude.Protocol

  alias Crucible.{
    BudgetTracker,
    ClientContext,
    PromptBuilder,
    SessionResumption,
    StuckTaskDetector
  }

  alias Crucible.Validation.Runner, as: ValidationRunner
  alias Crucible.PhaseRunner.{Detectors, Telemetry}

  @team_fallback_timeout_ms 300_000

  @doc "Run a phase from scratch (sentinel absent or stale)."
  @spec do_execute(Run.t(), Phase.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def do_execute(run, phase, runs_dir, opts) do
    agent_id = Keyword.get(opts, :agent_id, run.id)

    case BudgetTracker.budget_check(agent_id, task_id: run.id) do
      {:exceeded, tier, status} ->
        Logger.warning(
          "PhaseRunner: budget exceeded (#{tier}) for run #{run.id}: #{inspect(status)}"
        )

        :telemetry.execute(
          [:orchestrator, :budget, :check],
          %{system_time: System.system_time(:millisecond), spent: status.spent || 0},
          %{run_id: run.id, phase_id: phase.id, tier: tier, exceeded: true}
        )

        Telemetry.emit_trace(run, phase, "budget_exceeded", %{tier: tier, spent: status.spent})
        {:error, {:budget_exceeded, tier}}

      :ok ->
        run_phase(run, phase, runs_dir, opts)
    end
  end

  @doc "Handle pr_shepherd re-execution when sentinel exists but DoD failed."
  @spec validate_pr_shepherd(Run.t(), Phase.t(), map(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def validate_pr_shepherd(run, phase, sentinel_data, sentinel_path, runs_dir, opts) do
    verdict_path = Protocol.verdict_path(runs_dir, run.id, phase.id)

    if File.exists?(verdict_path) do
      case Protocol.read_review_verdict(verdict_path) do
        :block ->
          Logger.warning("PhaseRunner: PR shepherd DoD failed, forcing re-execution")
          Protocol.remove_sentinel(sentinel_path)
          do_execute(run, phase, runs_dir, opts)

        _ ->
          {:ok, %{status: :skipped, sentinel: sentinel_data}}
      end
    else
      {:ok, %{status: :skipped, sentinel: sentinel_data}}
    end
  end

  # --- Private ---

  defp run_phase(run, phase, runs_dir, opts) do
    started_at = System.monotonic_time(:millisecond)

    :telemetry.execute(
      [:orchestrator, :phase, :execute_start],
      %{system_time: System.system_time(:millisecond)},
      %{run_id: run.id, phase_id: phase.id, phase_type: phase.type}
    )

    adapter = adapter_for(phase.type)
    infra_home = Keyword.get(opts, :infra_home, File.cwd!())

    resume_session_id = SessionResumption.resolve_session_id(run, phase)
    session_resumed = resume_session_id != nil

    opts =
      if resume_session_id,
        do: Keyword.put(opts, :resume_session_id, resume_session_id),
        else: opts

    repo = Keyword.get(opts, :repo)
    client_context = if repo, do: ClientContext.build(repo, run.client_id), else: nil

    prompt =
      PromptBuilder.build(run, phase,
        infra_home: infra_home,
        client_context: client_context
      )

    loop_ref = Detectors.maybe_start_loop_detector(run, phase)
    stuck_pid = Detectors.maybe_start_stuck_detector(run, phase, infra_home)

    result = dispatch(adapter, run, phase, prompt, runs_dir, opts)

    if loop_ref, do: Process.cancel_timer(loop_ref)
    if stuck_pid, do: StuckTaskDetector.stop(stuck_pid)

    result = maybe_run_validation(run, phase, result, opts)

    sentinel_path = Protocol.sentinel_path(runs_dir, run.id, phase.id)
    ensure_sentinel(result, sentinel_path)

    duration_ms = System.monotonic_time(:millisecond) - started_at
    phase_status = if match?({:ok, _}, result), do: :completed, else: :failed

    :telemetry.execute(
      [:orchestrator, :phase, :execute_stop],
      %{duration: duration_ms},
      %{run_id: run.id, phase_id: phase.id, phase_type: phase.type, status: phase_status}
    )

    session_id = case result do
      {:ok, %{session_id: sid}} when is_binary(sid) and sid != "" -> sid
      _ -> nil
    end

    metrics = Telemetry.build_token_metrics(result, phase, duration_ms, session_resumed, session_id)
    Telemetry.emit_trace(run, phase, "token_efficiency", Map.from_struct(metrics))

    Telemetry.enrich_result(result, metrics)
  end

  defp dispatch(adapter, run, phase, prompt, runs_dir, opts) do
    case phase.type do
      :review_gate -> execute_review_gate(adapter, run, phase, prompt, runs_dir, opts)
      :team -> execute_with_team_fallback(adapter, run, phase, prompt, opts)
      _ -> adapter.execute_phase(run, phase, prompt, opts)
    end
  end

  defp execute_review_gate(adapter, run, phase, prompt, runs_dir, opts) do
    case adapter.execute_phase(run, phase, prompt, opts) do
      {:ok, result} ->
        verdict_path = Protocol.verdict_path(runs_dir, run.id, phase.id)

        case Protocol.read_review_verdict(verdict_path) do
          :block ->
            Logger.warning("PhaseRunner: review gate #{phase.id} returned BLOCK")
            Telemetry.emit_trace(run, phase, "verify_fail", %{verdict: "BLOCK"})
            {:error, {:review_gate_blocked, phase.id}}

          verdict ->
            Telemetry.emit_trace(run, phase, "verify_pass", %{verdict: to_string(verdict)})
            {:ok, Map.put(result, :verdict, verdict)}
        end

      error ->
        error
    end
  end

  defp execute_with_team_fallback(adapter, run, phase, prompt, opts) do
    case adapter.execute_phase(run, phase, prompt, opts) do
      {:ok, _} = success ->
        success

      {:error, :timeout} ->
        if Keyword.get(opts, :team_fallback_attempted, false) do
          Logger.error("PhaseRunner: team fallback also timed out for phase #{phase.id}")
          {:error, :timeout}
        else
          Logger.warning(
            "PhaseRunner: team phase #{phase.id} timed out, falling back to session mode"
          )

          session_opts =
            opts
            |> Keyword.put(:team_fallback_attempted, true)
            |> Keyword.put(:timeout_ms, @team_fallback_timeout_ms)

          Adapter.ClaudePort.execute_phase(run, phase, prompt, session_opts)
        end

      error ->
        error
    end
  end

  defp maybe_run_validation(_run, _phase, {:error, _} = error, _opts), do: error

  defp maybe_run_validation(run, phase, {:ok, result}, opts) do
    checks = Keyword.get(opts, :validation_checks, [])

    if checks == [] do
      {:ok, result}
    else
      run_validation_checks(run, phase, result, checks, opts)
    end
  end

  defp run_validation_checks(run, phase, result, checks, opts) do
    validation_started = System.monotonic_time(:millisecond)

    Logger.info("PhaseRunner: running #{length(checks)} validation checks for phase #{phase.id}")

    working_dir = run.workspace_path || Keyword.get(opts, :infra_home) || File.cwd!()

    validation_opts = [
      working_dir: working_dir,
      run_id: run.id,
      phase_id: phase.id,
      timeout_ms: Keyword.get(opts, :validation_timeout_ms, 60_000)
    ]

    validation_result = ValidationRunner.run_checks(checks, validation_opts)
    validation_duration = System.monotonic_time(:millisecond) - validation_started

    :telemetry.execute(
      [:orchestrator, :validation, :complete],
      %{duration: validation_duration},
      %{
        run_id: run.id,
        phase_id: phase.id,
        status: validation_result.status,
        total: length(checks),
        passed: length(validation_result.passed),
        failed: length(validation_result.failed)
      }
    )

    Telemetry.emit_trace(run, phase, "validation_complete", %{
      status: validation_result.status,
      duration_ms: validation_duration,
      passed: length(validation_result.passed),
      failed: length(validation_result.failed),
      errors: Enum.map(validation_result.failed, & &1.message)
    })

    case validation_result.status do
      :pass ->
        {:ok, Map.put(result, :validation, validation_result)}

      :fail ->
        Logger.warning(
          "PhaseRunner: validation failed for phase #{phase.id}: #{inspect(validation_result.failed)}"
        )

        {:error, {:validation_failed, validation_result}}
    end
  end

  defp ensure_sentinel({:ok, result}, sentinel_path) do
    # Elixir is the authoritative sentinel writer — always write with metadata
    data =
      %{"status" => "done", "writer" => "elixir",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()}
      |> maybe_put("cost_usd", result[:cost_usd])
      |> maybe_put("turns", result[:turns])
      |> maybe_put("session_id", result[:session_id])

    Protocol.write_sentinel(sentinel_path, data)
  end

  defp ensure_sentinel(_, _), do: :ok

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp adapter_for(:session), do: sdk_or_port()
  defp adapter_for(:team), do: sdk_or_port()
  defp adapter_for(:api), do: Adapter.ClaudeApi
  defp adapter_for(:review_gate), do: sdk_or_port()
  defp adapter_for(:pr_shepherd), do: sdk_or_port()
  defp adapter_for(:preflight), do: Adapter.ClaudeHook
  defp adapter_for(_), do: sdk_or_port()

  defp sdk_or_port do
    if Crucible.FeatureFlags.enabled?(:sdk_port_adapter),
      do: Adapter.ClaudeSdk,
      else: Adapter.ClaudePort
  end
end
