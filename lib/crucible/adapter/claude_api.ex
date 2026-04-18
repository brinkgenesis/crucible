defmodule Crucible.Adapter.ClaudeApi do
  @moduledoc """
  HTTP-based adapter: calls the TypeScript model router via HTTP API.
  Used for API-type phases that don't need a full Claude CLI session.
  Supports checkpoint/recovery, quality gate validation, prompt hint injection,
  and dynamic budget from run context.
  """
  @behaviour Crucible.Adapter.Behaviour

  require Logger

  alias Crucible.Claude.Protocol
  alias Crucible.BudgetTracker
  alias Crucible.Events
  alias Crucible.ExternalCircuitBreaker
  alias Crucible.FeatureFlags
  alias Crucible.Sandbox
  alias Crucible.SelfImprovement

  @default_router_url Application.compile_env(
                        :crucible,
                        :ts_dashboard_url,
                        "http://localhost:4800"
                      )
  @default_max_turns 20
  @default_session_budget 2.0
  @team_budget 5.0
  @checkpoint_version 1

  @impl true
  def execute_phase(run, phase, prompt, opts \\ []) do
    router_url = Keyword.get(opts, :router_url, @default_router_url)
    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)
    runs_dir = Keyword.get(opts, :runs_dir, ".claude-flow/runs")
    complexity = Keyword.get(opts, :complexity, 5)

    Logger.metadata(run_id: run.id, phase_id: phase.id)

    budget = phase_budget(phase.type, run)
    checkpoint = checkpoint_path(runs_dir, run.id, phase.id)

    # Check for checkpoint (resume from previous attempt)
    {resume_turn, prior_messages} = load_checkpoint(checkpoint)

    body = %{
      prompt: prompt,
      complexity: complexity,
      run_id: run.id,
      phase_id: phase.id,
      max_turns: max_turns,
      budget_usd: budget,
      resume_turn: resume_turn,
      system_context: build_system_context(run, phase)
    }

    body = if prior_messages, do: Map.put(body, :messages, prior_messages), else: body

    # Sandbox isolation: acquire container and include config in HTTP body
    {body, _sandbox_id} =
      if FeatureFlags.enabled?(:sandbox_enabled) do
        workspace = Keyword.get(opts, :workspace_path, run[:workspace_path] || "/tmp/sandbox-#{run.id}")

        case Sandbox.Manager.acquire(run.id, workspace_path: workspace) do
          {:ok, sid} ->
            sandbox_config = Application.get_env(:crucible, :sandbox, [])

            sandbox_body = %{
              enabled: true,
              container_id: sid,
              mode: Keyword.get(sandbox_config, :mode, :local) |> to_string(),
              policy: Keyword.get(sandbox_config, :policy_preset, :standard) |> to_string()
            }

            {Map.put(body, :sandbox, sandbox_body), sid}

          {:error, reason} ->
            Logger.warning("ClaudeApi: sandbox acquire failed (#{inspect(reason)}), running unsandboxed")
            {body, nil}
        end
      else
        {body, nil}
      end

    Logger.info(
      "ClaudeApi: executing run=#{run.id} phase=#{phase.id} (turns=#{max_turns}, budget=$#{budget})"
    )

    case ExternalCircuitBreaker.check(:model_router) do
      {:blocked, reason} ->
        Logger.warning("ClaudeApi: circuit breaker blocked — #{reason}")
        {:error, :circuit_open}

      :ok ->
        do_request(
          router_url,
          body,
          phase,
          run,
          runs_dir,
          checkpoint,
          resume_turn,
          prior_messages
        )
    end
  end

  @impl true
  def cleanup_artifacts(run, phase) do
    runs_dir = ".claude-flow/runs"
    cleanup_checkpoint(checkpoint_path(runs_dir, run.id, phase.id))

    # Release sandbox containers for this run
    if FeatureFlags.enabled?(:sandbox_enabled) do
      Sandbox.Manager.release_for_run(run.id)
    end

    :ok
  end

  # --- Private ---

  defp do_request(router_url, body, phase, run, runs_dir, checkpoint, resume_turn, prior_messages) do
    req_opts = [
      json: body,
      receive_timeout: phase.timeout_ms,
      connect_options: [timeout: 10_000]
    ]

    case Req.post("#{router_url}/api/route", req_opts) do
      {:ok, %{status: 200, body: response}} ->
        ExternalCircuitBreaker.record_success(:model_router)
        handle_success(run, phase, response, runs_dir, checkpoint)

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error("ClaudeApi: HTTP #{status} for run=#{run.id} phase=#{phase.id}")
        ExternalCircuitBreaker.record_failure(:model_router)

        if status in [429, 500, 502, 503, 504] do
          save_checkpoint(checkpoint, resume_turn, prior_messages)
        end

        {:error, {:http_error, status, resp_body}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        Logger.error("ClaudeApi: timeout for run=#{run.id} phase=#{phase.id}")
        ExternalCircuitBreaker.record_failure(:model_router)
        save_checkpoint(checkpoint, resume_turn, prior_messages)
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("ClaudeApi: request failed for run=#{run.id}: #{inspect(reason)}")
        ExternalCircuitBreaker.record_failure(:model_router)
        {:error, reason}
    end
  end

  defp handle_success(run, phase, response, runs_dir, checkpoint) do
    cost = get_in(response, ["usage", "cost"]) || get_in(response, ["cost"])
    if cost, do: BudgetTracker.record_cost(run.id, cost)

    tool_calls = get_in(response, ["usage", "toolCalls"]) || 0
    turns = get_in(response, ["usage", "turns"]) || 0
    input_tokens = get_in(response, ["usage", "inputTokens"]) || 0
    output_tokens = get_in(response, ["usage", "outputTokens"]) || 0

    # Per-turn telemetry for API phases (enables LiveView and Grafana monitoring)
    :telemetry.execute(
      [:infra, :api_phase, :turn],
      %{
        tokens: input_tokens + output_tokens,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        cost: cost || 0.0,
        tool_calls: tool_calls,
        turns: turns
      },
      %{run_id: run.id, phase_id: phase.id, phase_type: phase.type}
    )

    # Broadcast for LiveView consumption
    Events.broadcast_phase_event(run.id, phase.id, :phase_turn_completed, %{
      turns: turns,
      tool_calls: tool_calls,
      cost: cost,
      tokens: input_tokens + output_tokens
    })

    if quality_gate_failed?(phase.type, tool_calls, turns) do
      Logger.warning(
        "ClaudeApi: quality gate failed for phase #{phase.id} (#{tool_calls} tools, #{turns} turns)"
      )

      # Broadcast quality gate failure for trace visibility
      Events.broadcast_phase_event(run.id, phase.id, :quality_gate_failed, %{
        tool_calls: tool_calls,
        turns: turns,
        reason: "No tool calls and <= 1 turn — phase produced no meaningful work",
        phase_type: phase.type
      })

      cleanup_checkpoint(checkpoint)
      {:error, {:quality_gate_failed, phase.id}}
    else
      sentinel_path = Protocol.sentinel_path(runs_dir, run.id, phase.id)

      Protocol.write_sentinel(sentinel_path, %{
        executionType: "api",
        model: Map.get(response, "model"),
        turns: turns,
        cost: cost
      })

      cleanup_checkpoint(checkpoint)

      {:ok,
       %{
         status: :completed,
         response: response,
         cost: cost,
         turns: turns,
         tool_calls: tool_calls
       }}
    end
  end

  defp phase_budget(:team, _run), do: @team_budget

  defp phase_budget(_type, run) do
    cond do
      is_map(run) and is_number(Map.get(run, :budget_usd)) -> run.budget_usd
      is_map(run) and is_number(Map.get(run, :phase_budget_usd)) -> run.phase_budget_usd
      true -> @default_session_budget
    end
  end

  defp build_system_context(run, phase) do
    parts = [
      "Run ID: #{run.id}",
      "Phase: #{phase.name} (#{phase.type})",
      "Working directory: #{run.workspace_path || File.cwd!()}"
    ]

    parts =
      if run.plan_note,
        do: parts ++ ["Plan note path: #{run.plan_note}"],
        else: parts

    # Inject self-improvement prompt hints for this phase type
    workflow_name = Map.get(run, :workflow_type) || Map.get(run, :workflow_name)

    hints =
      safe_read_hints(workflow_name, phase.type)

    parts =
      case hints do
        [_ | _] ->
          hint_block = Enum.map_join(hints, "\n", &("- " <> &1))
          parts ++ ["\n## Learned Hints\n#{hint_block}"]

        _ ->
          parts
      end

    Enum.join(parts, "\n")
  end

  defp safe_read_hints(workflow_name, phase_type) do
    SelfImprovement.read_prompt_hints_for_phase(workflow_name, phase_type)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp checkpoint_path(runs_dir, run_id, phase_id) do
    Path.join(runs_dir, "#{run_id}-#{phase_id}.checkpoint.json")
  end

  defp load_checkpoint(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"version" => v, "turn" => turn, "messages" => messages}}
          when v == @checkpoint_version ->
            Logger.info("ClaudeApi: resuming from checkpoint at turn #{turn}")
            {turn, messages}

          {:ok, %{"turn" => turn, "messages" => messages}} when is_integer(turn) ->
            # Legacy checkpoint without version — accept but log warning
            Logger.warning(
              "ClaudeApi: checkpoint at #{path} missing version tag, accepting as legacy"
            )

            {turn, messages}

          {:ok, %{"version" => v}} ->
            Logger.warning(
              "ClaudeApi: checkpoint version mismatch (got #{v}, expected #{@checkpoint_version}), starting fresh"
            )

            {0, nil}

          _ ->
            {0, nil}
        end

      {:error, _} ->
        {0, nil}
    end
  end

  defp save_checkpoint(path, turn, messages) do
    File.mkdir_p!(Path.dirname(path))

    data = %{
      version: @checkpoint_version,
      turn: turn,
      messages: messages,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case Jason.encode(data) do
      {:ok, json} -> File.write!(path, json)
      _ -> :ok
    end
  end

  defp cleanup_checkpoint(path) do
    File.rm(path)
    :ok
  end

  defp quality_gate_failed?(type, tool_calls, turns)
       when type in [:session, :team, :pr_shepherd] do
    tool_calls == 0 and turns <= 1
  end

  defp quality_gate_failed?(_type, _tool_calls, _turns), do: false
end
