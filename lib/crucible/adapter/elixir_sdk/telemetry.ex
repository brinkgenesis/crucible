defmodule Crucible.Adapter.ElixirSdk.Telemetry do
  @moduledoc """
  Telemetry emission for the native Elixir SDK adapter.

  Feeds the three sinks that power the card detail UI — TraceEventWriter
  (trace_events table + JSONL), CostEventWriter (cost-events.jsonl), and
  two plain files (`agent-lifecycle.jsonl`, per-phase session logs).

  The SdkPort adapter gets these for free from the Node bridge stream;
  ElixirSdk has to emit them itself or Plan/Agents/Sessions/Logs are blank.
  """

  require Logger

  alias Crucible.{CostEventWriter, TraceEventWriter}

  @logs_rel ".claude-flow/logs"
  @lifecycle_rel "agent-lifecycle.jsonl"
  @sessions_subdir "sessions"
  @adapter_name "elixir_sdk"

  @doc "Emit phase_start trace event, agent spawn lifecycle rows, and open the session log."
  @spec phase_start(map(), map(), String.t(), [String.t()]) :: :ok
  def phase_start(run, phase, session_id, agent_names) do
    now = iso_now()
    agent_names = Enum.uniq(agent_names)

    emit_trace(run, phase, session_id, "phase_start", nil, nil, %{
      "phaseName" => Map.get(phase, :name) || phase.id,
      "phaseType" => phase_type_string(phase),
      "agents" => agent_names,
      "adapter" => @adapter_name
    })

    Enum.each(agent_names, fn name ->
      write_lifecycle(%{
        "run_id" => run.id,
        "phase_id" => phase.id,
        "agent_type" => name,
        "event" => "spawned",
        "session_id" => session_id,
        "timestamp" => now
      })
    end)

    ensure_session_log(run.id, phase.id)
    append_session_log(run.id, phase.id, "=== phase_start #{phase.id} (#{@adapter_name}) ===")
    :ok
  end

  @doc "Emit tool_call trace event and append to the session log."
  @spec record_tool_call(map(), map(), String.t(), map()) :: :ok
  def record_tool_call(run, phase, session_id, ev) do
    tool = Map.get(ev, :name)
    input = Map.get(ev, :input)
    agent_id = Map.get(ev, :agent_id)
    detail = tool_detail(tool, input)

    emit_trace(
      run,
      phase,
      session_id,
      "tool_call",
      tool,
      detail,
      %{
        "toolUseId" => Map.get(ev, :tool_use_id),
        "filePath" => file_path_from_input(input),
        "adapter" => @adapter_name
      },
      agent_id
    )

    append_session_log(run.id, phase.id, "[tool_call] #{tool} #{short_json(input)}")
    :ok
  end

  @doc "Append to the session log when a tool_result arrives. No DB event — avoid doubling DB volume."
  @spec record_tool_result(map(), map(), map()) :: :ok
  def record_tool_result(run, phase, ev) do
    tool = Map.get(ev, :name)
    output = Map.get(ev, :output)
    snippet = output |> to_string() |> String.slice(0, 240)
    append_session_log(run.id, phase.id, "[tool_result] #{tool} → #{snippet}")
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Emit phase_end trace + per-session token_efficiency event with cost/token metadata,
  write the cost_event line, and record agent completion lifecycle rows.
  """
  @spec phase_end(map(), map(), String.t(), [String.t()], map(), String.t()) :: :ok
  def phase_end(run, phase, session_id, agent_names, result, model) do
    now = iso_now()
    usage = Map.get(result, :usage) || %{}
    input = usage[:input] || 0
    output = usage[:output] || 0
    cache_read = usage[:cache_read] || 0
    cost_usd = Map.get(result, :cost) || 0.0
    turns = Map.get(result, :turns) || 0
    tool_calls = Map.get(result, :tool_calls) || 0

    # phase_end trace — drives the detail_phases sidebar.
    emit_trace(run, phase, session_id, "phase_end", nil, nil, %{
      "status" => "done",
      "adapter" => @adapter_name,
      "structuredOutput" => %{
        "execution" => %{
          "filesModified" => [],
          "filesCreated" => []
        }
      }
    })

    # token_efficiency — same shape ClaudeSdk emits, gives Sessions tab its
    # per-session totals via metadata fragments in db_sessions_for_run.
    emit_trace(run, phase, session_id, "token_efficiency", nil, nil, %{
      "inputTokens" => input,
      "outputTokens" => output,
      "cacheReadTokens" => cache_read,
      "costUsd" => cost_usd,
      "model" => model,
      "turns" => turns,
      "toolCalls" => tool_calls,
      "adapter" => @adapter_name
    })

    # cost-events.jsonl: gives the non-DB fallback reader a session row.
    CostEventWriter.write(%{
      "type" => "session_summary",
      "runId" => run.id,
      "phaseId" => phase.id,
      "sessionId" => session_id,
      "model" => model,
      "inputTokens" => input,
      "outputTokens" => output,
      "cacheReadTokens" => cache_read,
      "costUsd" => cost_usd,
      "turns" => turns,
      "toolCalls" => tool_calls,
      "timestamp" => now,
      "adapter" => @adapter_name
    })

    Enum.each(Enum.uniq(agent_names), fn name ->
      write_lifecycle(%{
        "run_id" => run.id,
        "phase_id" => phase.id,
        "agent_type" => name,
        "event" => "completed",
        "session_id" => session_id,
        "timestamp" => now
      })
    end)

    append_session_log(
      run.id,
      phase.id,
      "=== phase_end #{phase.id} turns=#{turns} tools=#{tool_calls} cost=$#{Float.round(cost_usd * 1.0, 4)} ==="
    )

    :ok
  end

  # ── Internals ──────────────────────────────────────────────────────────

  defp emit_trace(run, phase, session_id, event_type, tool, detail, metadata, agent_id \\ nil) do
    payload = %{
      "traceId" => "elixir-sdk-#{run.id}-#{phase.id}-#{System.unique_integer([:positive])}",
      "runId" => run.id,
      "phaseId" => phase.id,
      "sessionId" => session_id,
      "agentId" => agent_id,
      "eventType" => event_type,
      "tool" => tool,
      "detail" => detail,
      "clientId" => Map.get(run, :client_id),
      "metadata" => metadata,
      "timestamp" => iso_now()
    }

    TraceEventWriter.write(run.id, payload)
    :ok
  rescue
    e ->
      Logger.debug("ElixirSdk.Telemetry.emit_trace dropped: #{Exception.message(e)}")
      :ok
  end

  defp write_lifecycle(entry) do
    path = Path.join([repo_root(), @logs_rel, @lifecycle_rel])

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(entry) do
      File.write(path, json <> "\n", [:append])
    else
      _ -> :ok
    end
  end

  defp ensure_session_log(run_id, phase_id) do
    path = session_log_path(run_id, phase_id)
    File.mkdir_p(Path.dirname(path))
    unless File.exists?(path), do: File.write(path, "")
    :ok
  end

  defp append_session_log(run_id, phase_id, line) do
    path = session_log_path(run_id, phase_id)
    File.mkdir_p(Path.dirname(path))
    stamp = iso_now()
    File.write(path, "[#{stamp}] #{line}\n", [:append])
    :ok
  rescue
    _ -> :ok
  end

  defp session_log_path(run_id, phase_id) do
    Path.join([repo_root(), @logs_rel, @sessions_subdir, "#{run_id}-#{phase_id}.log"])
  end

  defp repo_root do
    Application.get_env(:crucible, :orchestrator, [])
    |> Keyword.get(:repo_root, File.cwd!())
  end

  defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp phase_type_string(%{type: t}) when is_atom(t), do: Atom.to_string(t)
  defp phase_type_string(%{type: t}) when is_binary(t), do: t
  defp phase_type_string(_), do: "session"

  defp tool_detail(_tool, nil), do: nil

  defp tool_detail(_tool, input) when is_map(input) do
    input
    |> Map.get("file_path")
    |> Kernel.||(Map.get(input, "path"))
    |> Kernel.||(Map.get(input, "command"))
    |> Kernel.||(short_json(input))
  end

  defp tool_detail(_tool, input), do: short_json(input)

  defp file_path_from_input(nil), do: nil

  defp file_path_from_input(input) when is_map(input),
    do: Map.get(input, "file_path") || Map.get(input, "path")

  defp file_path_from_input(_), do: nil

  defp short_json(nil), do: nil

  defp short_json(val) when is_map(val) or is_list(val) do
    case Jason.encode(val) do
      {:ok, s} -> String.slice(s, 0, 200)
      _ -> nil
    end
  end

  defp short_json(val), do: val |> to_string() |> String.slice(0, 200)
end
