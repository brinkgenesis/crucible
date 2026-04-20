defmodule Crucible.Adapter.ClaudeSdk do
  @moduledoc """
  SDK Port adapter: wraps the Claude Agent SDK via an Erlang Port to a Node.js subprocess.

  Instead of tmux (ClaudePort), this adapter spawns `bridge/src/sdk-port-bridge.ts`
  which calls `@anthropic-ai/claude-agent-sdk` query() and streams results as JSON.

  OTP guarantees:
  * SdkPort started under DynamicSupervisor — no orphaned processes on app shutdown
  * Circuit breaker prevents cascading failures when SDK bridge is unhealthy
  * try/after ensures GenServer cleanup even on unexpected exits
  * Retry with exponential backoff (skips retries on circuit-open)

  Benefits: structured results, real-time tool event streaming, no filesystem polling,
  OTP supervision, per-phase permissions/budget/model via TS resolver functions.
  """
  @behaviour Crucible.Adapter.Behaviour

  require Logger

  alias Crucible.Adapter.SdkPort
  alias Crucible.BudgetTracker
  alias Crucible.Claude.Protocol
  alias Crucible.ExternalCircuitBreaker

  @max_retries 2
  @circuit_breaker_service :sdk_port

  @impl true
  def execute_phase(run, phase, prompt, opts \\ []) do
    infra_home = run.workspace_path || Keyword.get(opts, :infra_home) || File.cwd!()
    runs_dir = Keyword.get(opts, :runs_dir, ".claude-flow/runs")

    config = %{
      prompt: prompt,
      run_id: run.id,
      phase_id: phase.id,
      card_id: run.card_id,
      infra_home: infra_home,
      repo_root: repo_root(),
      phase_type: Atom.to_string(phase.type),
      phase_name: phase.name,
      routing_profile: phase.routing_profile,
      agents: extract_agent_roles(phase.agents),
      timeout_ms: phase.timeout_ms,
      budget_usd: Keyword.get(opts, :phase_budget_usd) || phase.estimated_cost_usd,
      max_turns: Keyword.get(opts, :max_turns),
      producer_pid: Keyword.get(opts, :producer_pid),
      run: run_to_map(run),
      phase: phase_to_map(phase)
    }

    Logger.info(
      "ClaudeSdk: starting SDK port for run=#{run.id} phase=#{phase.id} (#{phase.type})"
    )

    execute_with_retry(run, phase, config, infra_home, runs_dir, 0)
  end

  @impl true
  def cleanup_artifacts(_run, _phase), do: :ok

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp execute_with_retry(run, phase, config, infra_home, runs_dir, attempt) do
    # Circuit breaker gate — fail fast if SDK bridge is unhealthy
    case check_circuit_breaker() do
      {:blocked, reason} ->
        Logger.warning("ClaudeSdk: circuit breaker open — #{inspect(reason)}")
        {:error, {:circuit_open, reason}}

      :ok ->
        case do_execute(config, phase.timeout_ms) do
          {:ok, result} ->
            ExternalCircuitBreaker.record_success(@circuit_breaker_service)

            if result.cost, do: BudgetTracker.record_cost(run.id, result.cost)

            sentinel_path = Protocol.sentinel_path(runs_dir, run.id, phase.id)

            Protocol.write_sentinel(sentinel_path, %{
              cost_usd: result.cost || 0,
              turns: result.turns || 0,
              session: result.session_id || "unknown"
            })

            {:ok, result}

          {:error, reason} when attempt < @max_retries ->
            ExternalCircuitBreaker.record_failure(@circuit_breaker_service)

            Logger.warning(
              "ClaudeSdk: #{inspect(reason)} for run=#{run.id} phase=#{phase.id}, " <>
                "retry #{attempt + 1}/#{@max_retries}"
            )

            Process.sleep(3_000 * (attempt + 1))
            execute_with_retry(run, phase, config, infra_home, runs_dir, attempt + 1)

          {:error, :timeout} ->
            ExternalCircuitBreaker.record_failure(@circuit_breaker_service)
            Logger.error("ClaudeSdk: timeout for run=#{run.id} phase=#{phase.id}")
            {:error, :timeout}

          {:error, reason} ->
            ExternalCircuitBreaker.record_failure(@circuit_breaker_service)

            Logger.error(
              "ClaudeSdk: failed for run=#{run.id} phase=#{phase.id}: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  defp do_execute(config, timeout_ms) do
    case start_supervised_port(config) do
      {:ok, pid} ->
        try do
          SdkPort.await_result(pid, timeout_ms)
        after
          # Guarantee cleanup — GenServer.stop triggers terminate/2 which kills the Port
          if Process.alive?(pid) do
            try do
              GenServer.stop(pid, :normal, 5_000)
            catch
              :exit, _ -> :ok
            end
          end
        end

      {:error, reason} ->
        {:error, {:port_start_failed, reason}}
    end
  end

  defp start_supervised_port(config) do
    DynamicSupervisor.start_child(
      Crucible.SdkPortSupervisor,
      {SdkPort, config}
    )
  end

  defp check_circuit_breaker do
    ExternalCircuitBreaker.check(@circuit_breaker_service)
  rescue
    # Circuit breaker not started (test env, standalone mode) — allow through
    _ -> :ok
  end

  defp repo_root do
    Application.get_env(:crucible, :orchestrator, [])
    |> Keyword.get(:repo_root, File.cwd!())
  end

  defp extract_agent_roles(agents) when is_list(agents) do
    Enum.map(agents, fn
      %{role: role} -> role
      %{"role" => role} -> role
      role when is_binary(role) -> role
      role when is_atom(role) -> Atom.to_string(role)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_agent_roles(_), do: []

  defp run_to_map(%{} = run) do
    %{
      runId: run.id,
      workflowName: run.workflow_type,
      cardId: run.card_id,
      clientId: run.client_id,
      planNote: run.plan_note,
      planSummary: run.plan_summary,
      branch: run.branch,
      taskDescription: run.task_description,
      executionType: run.execution_type
    }
  end

  defp phase_to_map(%{} = phase) do
    %{
      id: phase.id,
      phaseName: phase.name,
      type: Atom.to_string(phase.type),
      phaseIndex: phase.phase_index,
      routingProfile: phase.routing_profile,
      agents: extract_agent_roles(phase.agents),
      timeoutMs: phase.timeout_ms
    }
  end
end
