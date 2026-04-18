defmodule Crucible.ContextManager do
  @moduledoc """
  Per-run context window management GenServer.

  Tracks token consumption per turn and triggers automatic summarization
  when context usage exceeds a threshold (default 85%). Uses a cheap model
  (Gemini Flash via model router, complexity 3) for summarization.

  Full conversation history is stored in Postgres for audit/replay.
  Summaries are injected as system message prefixes for subsequent turns.

  ## DeepAgents Parity

  Mirrors the `SummarizationMiddleware` pattern but with improvements:
  - Postgres-backed history (not in-memory Python dicts)
  - Cheap model for summarization (not same-model like DeepAgents)
  - Telemetry events for Grafana monitoring
  - Per-run isolation via GenServer (no shared global state)
  """

  use GenServer

  require Logger

  @default_context_limit 180_000
  @summarization_threshold 0.85
  @summarization_complexity 3
  @default_router_url Application.compile_env(
                        :crucible,
                        :ts_dashboard_url,
                        "http://localhost:4800"
                      )

  # --- Client API ---

  @doc "Starts a ContextManager for a specific run."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    name = via(run_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Record a conversation turn's token usage."
  @spec record_turn(String.t(), non_neg_integer(), map()) :: :ok
  def record_turn(run_id, phase_index, turn_data) do
    case lookup(run_id) do
      {:ok, pid} -> GenServer.cast(pid, {:record_turn, phase_index, turn_data})
      :not_found -> :ok
    end
  end

  @doc """
  Check if summarization is needed and return updated messages if so.
  Returns `{:ok, messages}` where messages may include a summary prefix.
  """
  @spec maybe_summarize(String.t(), [map()]) :: {:ok, [map()]}
  def maybe_summarize(run_id, messages) do
    case lookup(run_id) do
      {:ok, pid} -> GenServer.call(pid, {:maybe_summarize, messages})
      :not_found -> {:ok, messages}
    end
  end

  @doc "Get current context usage stats for a run."
  @spec stats(String.t()) :: map() | nil
  def stats(run_id) do
    case lookup(run_id) do
      {:ok, pid} -> GenServer.call(pid, :stats)
      :not_found -> nil
    end
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    context_limit = Keyword.get(opts, :context_limit, @default_context_limit)
    router_url = Keyword.get(opts, :router_url, @default_router_url)

    Logger.info("ContextManager started for run #{run_id} (limit=#{context_limit})")

    {:ok,
     %{
       run_id: run_id,
       context_limit: context_limit,
       router_url: router_url,
       total_tokens: 0,
       turn_count: 0,
       summaries: [],
       last_summary_at_tokens: 0
     }}
  end

  @impl true
  def handle_cast({:record_turn, phase_index, turn_data}, state) do
    tokens = Map.get(turn_data, :tokens) || Map.get(turn_data, "tokens", 0)
    role = Map.get(turn_data, :role) || Map.get(turn_data, "role", "assistant")
    content = Map.get(turn_data, :content) || Map.get(turn_data, "content", "")

    new_total = state.total_tokens + tokens
    new_turn = state.turn_count + 1

    # Persist to DB (best effort)
    persist_turn(state.run_id, phase_index, new_turn, role, content, tokens)

    {:noreply, %{state | total_tokens: new_total, turn_count: new_turn}}
  end

  @impl true
  def handle_call({:maybe_summarize, messages}, _from, state) do
    usage_ratio = state.total_tokens / max(state.context_limit, 1)

    if usage_ratio >= @summarization_threshold and
         state.total_tokens - state.last_summary_at_tokens > 10_000 do
      Logger.info(
        "ContextManager: triggering summarization for run #{state.run_id} " <>
          "(#{state.total_tokens}/#{state.context_limit} tokens, #{Float.round(usage_ratio * 100, 1)}%)"
      )

      case summarize_messages(messages, state) do
        {:ok, summary} ->
          :telemetry.execute(
            [:infra, :context, :summarized],
            %{tokens_before: state.total_tokens, summary_length: String.length(summary)},
            %{run_id: state.run_id}
          )

          summary_message = %{
            "role" => "system",
            "content" => "[Context Summary]\n#{summary}\n\n[End Summary — recent messages follow]"
          }

          # Keep only recent messages after summarization
          recent_count = min(length(messages), 6)
          recent = Enum.take(messages, -recent_count)
          summarized_messages = [summary_message | recent]

          # Cap summaries to last 10 to prevent unbounded memory growth
          capped_summaries =
            (state.summaries ++ [summary])
            |> Enum.take(-10)

          new_state = %{
            state
            | summaries: capped_summaries,
              last_summary_at_tokens: state.total_tokens
          }

          {:reply, {:ok, summarized_messages}, new_state}

        {:error, _reason} ->
          {:reply, {:ok, messages}, state}
      end
    else
      {:reply, {:ok, messages}, state}
    end
  end

  def handle_call(:stats, _from, state) do
    usage_ratio = state.total_tokens / max(state.context_limit, 1)

    {:reply,
     %{
       run_id: state.run_id,
       total_tokens: state.total_tokens,
       context_limit: state.context_limit,
       usage_ratio: Float.round(usage_ratio, 3),
       turn_count: state.turn_count,
       summary_count: length(state.summaries)
     }, state}
  end

  # --- Private ---

  defp summarize_messages(messages, state) do
    conversation_text =
      messages
      |> Enum.map(fn msg ->
        role = Map.get(msg, "role", "unknown")
        content = Map.get(msg, "content", "")
        "#{role}: #{String.slice(content, 0, 2000)}"
      end)
      |> Enum.join("\n\n")

    prompt = """
    Summarize this conversation concisely, preserving:
    1. Key decisions and reasoning
    2. Current task state and progress
    3. Important constraints or requirements mentioned
    4. Any errors encountered and their resolution

    Keep the summary under 1000 tokens. Focus on what the agent needs to continue working.

    Conversation:
    #{String.slice(conversation_text, 0, 8000)}
    """

    body = %{
      prompt: prompt,
      complexity: @summarization_complexity,
      run_id: state.run_id,
      system_context: "You are a conversation summarizer. Be concise and factual."
    }

    case Req.post("#{state.router_url}/api/route", json: body, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: %{"response" => response}}} ->
        content = extract_content(response)
        {:ok, content}

      {:ok, %{status: 200, body: %{"content" => content}}} ->
        {:ok, content}

      {:ok, %{status: status}} ->
        Logger.warning("ContextManager: summarization returned HTTP #{status}")
        {:error, :http_error}

      {:error, reason} ->
        Logger.warning("ContextManager: summarization failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("ContextManager: summarization error: #{Exception.message(e)}")
      {:error, :exception}
  end

  defp extract_content(response) when is_binary(response), do: response
  defp extract_content(%{"content" => c}) when is_binary(c), do: c
  defp extract_content(response) when is_map(response), do: inspect(response)
  defp extract_content(other), do: to_string(other)

  defp persist_turn(run_id, phase_index, turn_number, role, content, token_count) do
    Crucible.Repo.insert(%Crucible.Schema.ConversationHistory{
      run_id: run_id,
      phase_index: phase_index,
      turn_number: turn_number,
      role: role,
      content: String.slice(to_string(content), 0, 50_000),
      token_count: token_count
    })
  rescue
    _ -> :ok
  end

  defp via(run_id) do
    {:via, Registry, {Crucible.ContextManagerRegistry, run_id}}
  end

  defp lookup(run_id) do
    case Registry.lookup(Crucible.ContextManagerRegistry, run_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :not_found
    end
  end
end
