defmodule Crucible.Adapter.ElixirSdk do
  @moduledoc """
  Native-Elixir execution adapter.

  Drives `Crucible.ElixirSdk.Query` directly — no Node subprocess, no bridge.
  Implements the same `Crucible.Adapter.Behaviour` as the Node bridge so
  workflow YAMLs can swap between them with a single `adapter:` field.

  Pros: one runtime, supervised subagents, crash isolation per tool call.
  Cons: lacks MCP-server support and WebFetch/WebSearch tools — use the
  Node bridge (`Crucible.Adapter.ClaudeSdk`) if those are required.
  """

  @behaviour Crucible.Adapter.Behaviour

  require Logger

  alias Crucible.Adapter.ElixirSdk.Telemetry
  alias Crucible.BudgetTracker
  alias Crucible.Claude.Protocol
  alias Crucible.Context.KnowledgeInjector
  alias Crucible.ElixirSdk.Query
  alias Crucible.Events
  alias Crucible.ExternalCircuitBreaker
  alias Crucible.SelfImprovement

  @circuit_breaker_service :elixir_sdk
  @default_model "claude-sonnet-4-6"

  @impl true
  def execute_phase(run, phase, prompt, opts \\ []) do
    case check_circuit_breaker() do
      {:blocked, reason} ->
        Logger.warning("ElixirSdk: circuit open — #{inspect(reason)}")
        {:error, {:circuit_open, reason}}

      :ok ->
        do_execute(run, phase, prompt, opts)
    end
  end

  @impl true
  def cleanup_artifacts(_run, _phase), do: :ok

  # ── Internals ──────────────────────────────────────────────────────────────

  defp do_execute(run, phase, prompt, opts) do
    infra_home = run.workspace_path || Keyword.get(opts, :infra_home) || File.cwd!()
    runs_dir = Keyword.get(opts, :runs_dir, ".claude-flow/runs")
    model = Keyword.get(opts, :model, Map.get(phase, :primary_model) || @default_model)
    timeout_ms = phase.timeout_ms || 600_000
    session_id = generate_session_id()
    agent_names = agent_names_for(phase)

    Logger.info(
      "ElixirSdk: starting native query for run=#{run.id} phase=#{phase.id} (#{phase.type}) session=#{session_id}"
    )

    knowledge_sources = build_knowledge_sources(run, phase)

    safe_telemetry(fn -> Telemetry.phase_start(run, phase, session_id, agent_names) end)

    query_opts = [
      prompt: prompt,
      model: model,
      cwd: infra_home,
      system: Keyword.get(opts, :system),
      permission_mode: Keyword.get(opts, :permission_mode, :default),
      max_turns: Keyword.get(opts, :max_turns, 30),
      timeout_ms: timeout_ms,
      subscriber: self(),
      session_id: session_id,
      knowledge_sources: knowledge_sources
    ]

    started_at = System.monotonic_time(:millisecond)

    case Query.start_link(query_opts) do
      {:ok, pid} ->
        # Forward streaming events to the PubSub feed + trace stream so
        # LiveView can render live tool activity.
        link_event_forwarder(pid, run, phase, session_id)

        case Query.await(pid, timeout_ms) do
          {:ok, result} ->
            duration_ms = System.monotonic_time(:millisecond) - started_at
            ExternalCircuitBreaker.record_success(@circuit_breaker_service)
            maybe_record_cost(run.id, result, model)

            enriched_result = Map.put(result, :cost, estimate_cost(model, result.usage))

            safe_telemetry(fn ->
              Telemetry.phase_end(run, phase, session_id, agent_names, enriched_result, model)
            end)

            sentinel_path = Protocol.sentinel_path(runs_dir, run.id, phase.id)

            Protocol.write_sentinel(sentinel_path, %{
              adapter: "elixir_sdk",
              turns: result.turns,
              tool_calls: result.tool_calls,
              input_tokens: result.usage.input,
              output_tokens: result.usage.output,
              duration_ms: duration_ms,
              result_summary: String.slice(result.text || "", 0, 2000)
            })

            {:ok,
             %{
               status: :done,
               text: result.text,
               model: model,
               turns: result.turns,
               tool_call_count: result.tool_calls,
               input_tokens: result.usage.input,
               output_tokens: result.usage.output,
               cache_read_tokens: result.usage.cache_read,
               cost: enriched_result.cost,
               session_id: session_id
             }}

          {:error, :timeout} ->
            ExternalCircuitBreaker.record_failure(@circuit_breaker_service)
            Logger.error("ElixirSdk: timeout for run=#{run.id} phase=#{phase.id}")
            {:error, :timeout}

          {:error, reason} ->
            ExternalCircuitBreaker.record_failure(@circuit_breaker_service)
            Logger.error("ElixirSdk: run=#{run.id} phase=#{phase.id} failed: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:query_start_failed, reason}}
    end
  end

  defp link_event_forwarder(_query_pid, run, phase, session_id) do
    spawn_link(fn ->
      forward_loop(run, phase, session_id)
    end)
  end

  defp forward_loop(run, phase, session_id) do
    receive do
      {:crucible_sdk_event, %{type: :tool_call} = ev} ->
        safe_broadcast_tool(run, phase, ev, :start)
        safe_telemetry(fn -> Telemetry.record_tool_call(run, phase, session_id, ev) end)
        forward_loop(run, phase, session_id)

      {:crucible_sdk_event, %{type: :tool_result} = ev} ->
        safe_broadcast_tool(run, phase, ev, :complete)
        safe_telemetry(fn -> Telemetry.record_tool_result(run, phase, ev) end)
        forward_loop(run, phase, session_id)

      {:crucible_sdk_event, %{type: :result}} ->
        :ok

      {:crucible_sdk_event, _other} ->
        forward_loop(run, phase, session_id)
    end
  end

  defp safe_broadcast_tool(run, phase, ev, status) do
    try do
      Events.broadcast_phase_event(run.id, phase.id, :mcp_tool_call, %{
        tool: Map.get(ev, :name),
        adapter: "elixir_sdk",
        status: Atom.to_string(status),
        tool_use_id: Map.get(ev, :tool_use_id)
      })
    catch
      _kind, _err -> :ok
    end
  end

  defp safe_telemetry(fun) when is_function(fun, 0) do
    try do
      fun.()
    catch
      kind, err ->
        Logger.debug("ElixirSdk telemetry dropped: #{kind} #{inspect(err)}")
        :ok
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end

  defp agent_names_for(phase) do
    agents = Map.get(phase, :agents) || []

    names =
      agents
      |> Enum.map(fn
        %{role: role} when is_binary(role) -> role
        %{"role" => role} when is_binary(role) -> role
        role when is_binary(role) -> role
        role when is_atom(role) -> Atom.to_string(role)
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    if names == [] do
      # Phases without an explicit agents list (pr_shepherd, review_gate,
      # preflight) still need one row on the Agents tab so the UI renders
      # something per phase. Fall back to the phase type.
      [phase_fallback_name(phase)]
    else
      names
    end
  end

  defp phase_fallback_name(%{type: t}) when is_atom(t), do: Atom.to_string(t)
  defp phase_fallback_name(%{type: t}) when is_binary(t), do: t
  defp phase_fallback_name(%{name: n}) when is_binary(n), do: n
  defp phase_fallback_name(_), do: "session"

  defp check_circuit_breaker do
    ExternalCircuitBreaker.check(@circuit_breaker_service)
  rescue
    _ -> :ok
  end

  defp maybe_record_cost(run_id, result, model) do
    cost = estimate_cost(model, result.usage)
    if cost && cost > 0, do: BudgetTracker.record_cost(run_id, cost)
  end

  # Coarse pricing mirror of Crucible.Router.CostTable. Override via
  # Application.put_env(:crucible, :elixir_sdk_pricing, fn model, usage -> ... end).
  defp estimate_cost(model_id, usage) do
    case Application.get_env(:crucible, :elixir_sdk_pricing) do
      fun when is_function(fun, 2) ->
        fun.(model_id, usage)

      _ ->
        price = model_price(model_id)
        input_cost = usage.input / 1_000_000 * price.input
        cache_cost = usage.cache_read / 1_000_000 * (price.cache_read || price.input * 0.1)
        output_cost = usage.output / 1_000_000 * price.output
        input_cost + cache_cost + output_cost
    end
  end

  defp model_price("claude-opus-4-7"), do: %{input: 15.0, output: 75.0, cache_read: 1.5}
  defp model_price("claude-opus-4-6"), do: %{input: 15.0, output: 75.0, cache_read: 1.5}
  defp model_price("claude-sonnet-4-6"), do: %{input: 3.0, output: 15.0, cache_read: 0.3}
  defp model_price("claude-sonnet-4-5-20250929"), do: %{input: 3.0, output: 15.0, cache_read: 0.3}
  defp model_price("claude-haiku-4-5-20251001"), do: %{input: 0.8, output: 4.0, cache_read: 0.08}
  defp model_price(_), do: %{input: 0.0, output: 0.0, cache_read: nil}

  defp build_knowledge_sources(run, phase) do
    lessons = SelfImprovement.read_prompt_hints_for_phase(run.workflow_type, phase.type)
    handoffs = collect_prior_phase_handoffs(run, phase)

    KnowledgeInjector.build_workflow_sources(
      plan_note: run.plan_note,
      plan_summary: run.plan_summary,
      lessons: if(lessons != [], do: lessons, else: nil),
      handoff_summaries: if(handoffs != [], do: handoffs, else: nil)
    )
  end

  defp collect_prior_phase_handoffs(run, current_phase) do
    infra_home = run.workspace_path || File.cwd!()
    runs_dir = ".claude-flow/runs"
    phases = Map.get(run, :phases) || []

    phases
    |> Enum.take_while(fn p ->
      phase_id = if is_map(p), do: p["id"] || p[:id], else: nil
      phase_id != current_phase.id
    end)
    |> Enum.flat_map(fn p ->
      phase_id = if is_map(p), do: p["id"] || p[:id], else: to_string(p)
      sentinel = Protocol.sentinel_path(runs_dir, run.id, phase_id)
      path = Path.join(infra_home, sentinel)

      # Read raw sentinel JSON directly — Protocol.read_sentinel/2 strips
      # extra fields via parse_and_validate, so we parse the file ourselves
      # to access result_summary written by execute_phase.
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, data} ->
              summary = data["result_summary"] || data["resultSummary"] || ""
              if summary != "", do: [summary], else: []

            _ ->
              []
          end

        _ ->
          []
      end
    end)
  rescue
    _ -> []
  end
end
