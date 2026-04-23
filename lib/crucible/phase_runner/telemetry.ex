defmodule Crucible.PhaseRunner.Telemetry do
  @moduledoc """
  Trace emission, token-metric construction, and result enrichment for phase
  execution. Persistence is delegated to `Crucible.TraceEventWriter`, which
  owns both the JSONL log and the `trace_events` table.
  """

  require Logger

  alias Crucible.TraceEventWriter
  alias Crucible.Types.{Run, Phase, PhaseTokenMetrics}

  @doc "Emit a trace event to PubSub and persist it via TraceEventWriter (JSONL + DB)."
  @spec emit_trace(Run.t(), Phase.t(), String.t(), map()) :: :ok
  def emit_trace(run, phase, event_type, metadata) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    event = %{
      "traceId" => "phase-runner-#{run.id}-#{phase.id}-#{System.unique_integer([:positive])}",
      "eventType" => event_type,
      "runId" => run.id,
      "phaseId" => phase.id,
      "clientId" => Map.get(run, :client_id),
      "metadata" => metadata,
      "timestamp" => now
    }

    Phoenix.PubSub.broadcast(
      Crucible.PubSub,
      "orchestrator:traces",
      {:trace_event, event}
    )

    TraceEventWriter.write(run.id, event)
    :ok
  rescue
    e ->
      Logger.warning("PhaseRunner: emit_trace failed for run #{run.id}: #{Exception.message(e)}")
      :ok
  end

  @doc "Build a PhaseTokenMetrics struct from an execution result."
  @spec build_token_metrics(
          {:ok, map()} | {:error, term()},
          Phase.t(),
          non_neg_integer(),
          boolean(),
          String.t() | nil
        ) :: PhaseTokenMetrics.t()
  def build_token_metrics(result, phase, duration_ms, session_resumed, session_id \\ nil) do
    {exit_code, result_str} =
      case result do
        {:ok, %{exit_status: code}} -> {code, "done"}
        {:ok, _} -> {0, "done"}
        {:error, :timeout} -> {nil, "timeout"}
        {:error, _} -> {nil, "error"}
      end

    tokens = if session_id, do: read_session_tokens(session_id), else: %{}

    %PhaseTokenMetrics{
      session_resumed: session_resumed,
      retry_count: phase.retry_count,
      duration_ms: duration_ms,
      exit_code: exit_code,
      budget_usd: nil,
      input_tokens: Map.get(tokens, :input_tokens, 0),
      output_tokens: Map.get(tokens, :output_tokens, 0),
      cache_read_tokens: Map.get(tokens, :cache_read_tokens, 0),
      result: result_str
    }
  end

  @doc """
  Read token usage from a Claude Code session transcript.
  Sums input_tokens, output_tokens, and cache_read_input_tokens from all
  assistant messages in `~/.claude/projects/{slug}/{sessionId}.jsonl`.
  """
  @spec read_session_tokens(String.t()) :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer()
        }
  def read_session_tokens(session_id) when is_binary(session_id) and session_id != "" do
    # Claude Code stores transcripts under ~/.claude/projects/{slug}/{sessionId}.jsonl
    # The slug is derived from the working directory
    projects_dir = Path.join([System.user_home!(), ".claude", "projects"])

    transcript_path =
      case File.ls(projects_dir) do
        {:ok, slugs} ->
          Enum.find_value(slugs, fn slug ->
            path = Path.join([projects_dir, slug, "#{session_id}.jsonl"])
            if File.exists?(path), do: path
          end)

        _ ->
          nil
      end

    if transcript_path do
      sum_transcript_tokens(transcript_path)
    else
      %{input_tokens: 0, output_tokens: 0, cache_read_tokens: 0}
    end
  rescue
    e ->
      Logger.warning(
        "Telemetry: failed to read session tokens for #{session_id}: #{Exception.message(e)}"
      )

      %{input_tokens: 0, output_tokens: 0, cache_read_tokens: 0}
  end

  def read_session_tokens(_), do: %{input_tokens: 0, output_tokens: 0, cache_read_tokens: 0}

  defp sum_transcript_tokens(path) do
    path
    |> File.stream!()
    |> Enum.reduce(%{input_tokens: 0, output_tokens: 0, cache_read_tokens: 0}, fn line, acc ->
      case Jason.decode(line) do
        {:ok, %{"type" => "assistant", "message" => %{"usage" => usage}}} when is_map(usage) ->
          %{
            input_tokens: acc.input_tokens + (usage["input_tokens"] || 0),
            output_tokens: acc.output_tokens + (usage["output_tokens"] || 0),
            cache_read_tokens: acc.cache_read_tokens + (usage["cache_read_input_tokens"] || 0)
          }

        _ ->
          acc
      end
    end)
  rescue
    _ -> %{input_tokens: 0, output_tokens: 0, cache_read_tokens: 0}
  end

  @doc "Enrich a successful result map with token metrics and a session_id placeholder."
  @spec enrich_result({:ok, map()} | {:error, term()}, PhaseTokenMetrics.t()) ::
          {:ok, map()} | {:error, term()}
  def enrich_result({:ok, result}, metrics) do
    {:ok,
     result
     |> Map.put(:token_metrics, metrics)
     |> Map.put_new(:session_id, Map.get(result, :session_id))}
  end

  def enrich_result(error, _metrics), do: error
end
