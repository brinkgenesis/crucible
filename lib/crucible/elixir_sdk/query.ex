defmodule Crucible.ElixirSdk.Query do
  @moduledoc """
  Tool-use loop for the Anthropic Messages API.

  Owns the conversation for one agent session:
    1. Send the initial prompt (+ system + tools)
    2. Stream the response, reassembling content blocks from SSE deltas
    3. When the model stops with `stop_reason: "tool_use"`:
         - dispatch each `tool_use` block to the tool registry
         - append the tool results as a new `user` turn
         - send the next request
    4. When `stop_reason: "end_turn"`, emit `:result` and stop.

  Feature surface (see also Client):

    * Prompt caching: system prompt wrapped in cache_control ephemeral
    * Extended thinking blocks — accumulated, echoed to subscriber, fed back
    * Multi-modal content: image content blocks pass through
    * Session resumption: `resume_session_id` reads a Transcript to rebuild messages
    * Context usage: emitted after every turn as `:context_usage`
    * Model downshifting: when QuotaTracker reports the primary model is
      near-exhausted, we swap to the next-cheaper model and emit an event
    * Course correction: after each tool-use turn, analyse recent tool
      calls via CourseCorrector and inject a steering user message if we're looping
    * Agent definitions: `agent_type: "...name..."` applies AgentDef overrides
      (tools, model, system prompt, permission mode)
    * Control: `interrupt/1`, `set_model/2`, `set_permission_mode/2`,
      `inject_user_message/2`

  Events emitted to the subscriber (all as `{:crucible_sdk_event, event}`):

      %{type: :text_delta, text: "..."}
      %{type: :thinking_delta, thinking: "..."}
      %{type: :tool_call, tool_use_id: "...", name: "Bash", input: %{...}}
      %{type: :tool_result, tool_use_id: "...", name: "Bash", output: "..."}
      %{type: :context_usage, percentage: 42.5, ...}
      %{type: :api_retry, attempt: 1, delay_ms: 1500, ...}
      %{type: :model_downshift, from: "opus", to: "sonnet", reason: ...}
      %{type: :course_correction, message: "..."}
      %{type: :turn_complete, stop_reason: "end_turn"}
      %{type: :result, text: "...", usage: %{...}}
      %{type: :error, reason: ...}
  """

  use GenServer
  require Logger

  alias Crucible.Context.SnipCompact

  alias Crucible.ElixirSdk.{
    AgentDef,
    Client,
    ContextUsage,
    CourseCorrector,
    ToolRegistry,
    Transcript
  }

  @downshift_chain %{
    "claude-opus-4-7" => "claude-opus-4-6",
    "claude-opus-4-6" => "claude-sonnet-4-6",
    "claude-opus-4-5" => "claude-sonnet-4-5-20250929",
    "claude-sonnet-4-6" => "claude-haiku-4-5-20251001",
    "claude-sonnet-4-5-20250929" => "claude-haiku-4-5-20251001"
  }

  defstruct [
    :opts,
    :subscriber,
    :client_ref,
    :cwd,
    :model,
    :initial_model,
    :system_prompt,
    :tools,
    :max_turns,
    :permission_mode,
    :caller,
    :session_id,
    :thinking_budget,
    :agent_def,
    pending_inject: [],
    messages: [],
    current_blocks: %{},
    turn: 0,
    usage: %{input: 0, output: 0, cache_read: 0, cache_creation: 0},
    tool_calls: 0,
    tool_call_history: [],
    final_text: "",
    thinking_text: "",
    aborted?: false
  ]

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Start a new query.

  Options:

    Required:
      * `:prompt` — user prompt string (or `:resume_session_id` + continuation)
      * `:model` — Anthropic model id
      * `:cwd` — workspace directory

    Optional:
      * `:system` — system prompt
      * `:tools` — list of atom tool names (default: all registered)
      * `:agent_type` — AgentDef name; overrides tools/model/prompt/mode
      * `:max_turns` — default 20
      * `:permission_mode` — :default | :accept_edits | :bypass_permissions | :plan
      * `:subscriber` — pid for streaming events
      * `:max_tokens` — per-turn output cap (default 4096)
      * `:thinking_budget` — token budget for extended thinking (enables thinking block)
      * `:cache_system` — wrap system prompt in cache_control ephemeral (default true)
      * `:resume_session_id` — rebuild conversation from a prior Transcript
      * `:session_id` — override auto-generated session id (useful for resumption)
      * `:downshift?` — auto-downshift on quota exhaustion (default true)
      * `:api_key`, `:base_url`, `:anthropic_beta`, `:timeout_ms`, `:max_retries`
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Block until the query finishes. Returns `{:ok, result}` or `{:error, reason}`."
  @spec await(pid(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def await(pid, timeout_ms \\ 600_000) do
    GenServer.call(pid, :await, timeout_ms + 5_000)
  catch
    :exit, {:timeout, _} ->
      Process.exit(pid, :kill)
      {:error, :timeout}

    :exit, {:noproc, _} ->
      {:error, :noproc}
  end

  @doc "Interrupt the model mid-stream."
  def interrupt(pid), do: GenServer.cast(pid, :interrupt)

  @doc "Swap the model for subsequent turns."
  def set_model(pid, model), do: GenServer.cast(pid, {:set_model, model})

  @doc "Change permission mode for subsequent tool calls."
  def set_permission_mode(pid, mode),
    do: GenServer.cast(pid, {:set_permission_mode, mode})

  @doc """
  Inject a user message into the conversation. Used for course correction
  and manual follow-ups. The message is appended before the next turn
  starts (or immediately queued if we're mid-turn).
  """
  def inject_user_message(pid, message),
    do: GenServer.cast(pid, {:inject_user, message})

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    agent_def = AgentDef.lookup(Keyword.get(opts, :agent_type))
    session_id = Keyword.get(opts, :session_id) || generate_session_id()

    model =
      Keyword.get(opts, :model) ||
        (agent_def && agent_def.model) ||
        "claude-sonnet-4-6"

    initial_messages = build_initial_messages(opts, agent_def)

    state = %__MODULE__{
      opts: opts,
      subscriber: Keyword.get(opts, :subscriber, self()),
      cwd: Keyword.fetch!(opts, :cwd),
      model: model,
      initial_model: model,
      system_prompt: effective_system(opts, agent_def),
      tools: resolve_tools(opts, agent_def),
      max_turns:
        Keyword.get(opts, :max_turns) ||
          (agent_def && agent_def.max_turns) || 20,
      permission_mode:
        Keyword.get(opts, :permission_mode) ||
          (agent_def && agent_def.permission_mode) || :default,
      thinking_budget: Keyword.get(opts, :thinking_budget),
      session_id: session_id,
      agent_def: agent_def,
      messages: initial_messages
    }

    record_transcript(state, %{type: :session_start, session_id: session_id, model: model})

    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_call(:await, from, state) do
    {:noreply, %{state | caller: from}}
  end

  @impl true
  def handle_cast(:interrupt, state) do
    abort_stream(state)
    reply(state, {:ok, finalize(state, :interrupted)})
    {:stop, :normal, %{state | aborted?: true}}
  end

  def handle_cast({:set_model, model}, state), do: {:noreply, %{state | model: model}}

  def handle_cast({:set_permission_mode, mode}, state),
    do: {:noreply, %{state | permission_mode: mode}}

  def handle_cast({:inject_user, message}, state) do
    {:noreply, %{state | pending_inject: state.pending_inject ++ [message]}}
  end

  @impl true
  def handle_info(:tick, state) do
    if state.turn >= state.max_turns do
      reply(state, {:error, :max_turns_reached})
      {:stop, :normal, state}
    else
      state = flush_pending_inject(state)
      state = maybe_downshift(state)
      state = maybe_compact(state)
      {:ok, ref} = start_turn(state)
      {:noreply, %{state | client_ref: ref, current_blocks: %{}}}
    end
  end

  # ── SSE events from Client ───────────────────────────────────────────────

  def handle_info({:crucible_sdk, :message_start, _}, state), do: {:noreply, state}

  def handle_info(
        {:crucible_sdk, :content_block_start, %{"index" => idx, "content_block" => block}},
        state
      ) do
    blocks = Map.put(state.current_blocks, idx, init_block(block))
    {:noreply, %{state | current_blocks: blocks}}
  end

  def handle_info(
        {:crucible_sdk, :content_block_delta, %{"index" => idx, "delta" => delta}},
        state
      ) do
    blocks = Map.update(state.current_blocks, idx, %{}, &apply_delta(&1, delta))
    maybe_emit_delta(state, delta)
    {:noreply, %{state | current_blocks: blocks}}
  end

  def handle_info({:crucible_sdk, :content_block_stop, _}, state), do: {:noreply, state}

  def handle_info({:crucible_sdk, :message_delta, payload}, state) do
    usage = Map.get(payload, "usage", %{})
    updated_usage = merge_usage(state.usage, usage)
    stop_reason = get_in(payload, ["delta", "stop_reason"])

    new_state = %{state | usage: updated_usage}
    emit_context_usage(new_state)

    case stop_reason do
      "tool_use" ->
        handle_tool_use_turn(new_state)

      "end_turn" ->
        finish_ok(new_state)

      "max_tokens" ->
        reply(new_state, {:error, :max_tokens})
        {:stop, :normal, new_state}

      "stop_sequence" ->
        finish_ok(new_state)

      other ->
        Logger.debug("ElixirSdk.Query: unhandled stop_reason #{inspect(other)}")
        {:noreply, new_state}
    end
  end

  def handle_info({:crucible_sdk, :message_stop, _}, state), do: {:noreply, state}

  def handle_info({:crucible_sdk, :api_retry, payload}, state) do
    emit(state, %{
      type: :api_retry,
      attempt: Map.get(payload, :attempt),
      max: Map.get(payload, :max),
      error_status: Map.get(payload, :error_status),
      delay_ms: Map.get(payload, :delay_ms)
    })

    {:noreply, state}
  end

  def handle_info({:crucible_sdk, :rate_limit, payload}, state) do
    emit(state, Map.put(payload, :type, :rate_limit))
    {:noreply, state}
  end

  def handle_info({:crucible_sdk, :error, reason}, state) do
    reply(state, {:error, reason})
    {:stop, :normal, state}
  end

  def handle_info({:crucible_sdk, :done, _}, state), do: {:noreply, state}
  def handle_info({:crucible_sdk_task_ready, _}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Turn helpers ─────────────────────────────────────────────────────────

  defp start_turn(state) do
    Client.stream(
      api_key: Keyword.get(state.opts, :api_key) || System.get_env("ANTHROPIC_API_KEY"),
      base_url: Keyword.get(state.opts, :base_url),
      model: state.model,
      system: cacheable_system(state.system_prompt, Keyword.get(state.opts, :cache_system, true)),
      max_tokens: Keyword.get(state.opts, :max_tokens, 4096),
      messages: state.messages,
      tools: tool_schemas(state.tools),
      thinking: thinking_config(state),
      subscriber: self(),
      timeout_ms: Keyword.get(state.opts, :timeout_ms, 300_000),
      max_retries: Keyword.get(state.opts, :max_retries, 5),
      anthropic_beta: Keyword.get(state.opts, :anthropic_beta, [])
    )
  end

  defp handle_tool_use_turn(state) do
    assistant_blocks =
      state.current_blocks
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_idx, blk} -> finalize_block(blk) end)

    tool_calls_this_turn =
      assistant_blocks
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(fn b -> %{name: b["name"], input: b["input"]} end)

    history = state.tool_call_history ++ tool_calls_this_turn

    new_messages = state.messages ++ [%{role: "assistant", content: assistant_blocks}]

    raw_tool_results =
      assistant_blocks
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(fn block ->
        emit_and_record(state, %{
          type: :tool_call,
          tool_use_id: block["id"],
          name: block["name"],
          input: block["input"]
        })

        output = dispatch_tool(state, block)

        emit_and_record(state, %{
          type: :tool_result,
          tool_use_id: block["id"],
          name: block["name"],
          output: truncate(output, 20_000)
        })

        %{
          tool_use_id: block["id"],
          tool_name: block["name"],
          content: to_string(output)
        }
      end)

    # Compact tool outputs before appending to conversation history
    %{results: compacted, total_saved: saved} =
      SnipCompact.snip_compact_tool_results(raw_tool_results)

    if saved > 0 do
      Logger.debug("SnipCompact: saved ~#{saved} tokens across #{length(compacted)} tool results")

      :telemetry.execute(
        [:crucible, :snip_compact, :savings],
        %{tokens_saved: saved, tool_count: length(compacted)},
        %{session_id: state.session_id, turn: state.turn}
      )
    end

    tool_results =
      Enum.map(compacted, fn entry ->
        %{
          "type" => "tool_result",
          "tool_use_id" => entry.tool_use_id,
          "content" => entry.content
        }
      end)

    new_messages = new_messages ++ [%{role: "user", content: tool_results}]

    state = %{
      state
      | messages: new_messages,
        current_blocks: %{},
        turn: state.turn + 1,
        tool_calls: state.tool_calls + length(tool_results),
        tool_call_history: history
    }

    state = maybe_course_correct(state)

    send(self(), :tick)
    {:noreply, state}
  end

  defp finish_ok(state) do
    final_text = extract_final_text(state.current_blocks)
    thinking = extract_thinking(state.current_blocks)

    state = %{state | final_text: final_text, thinking_text: state.thinking_text <> thinking}

    emit(state, %{type: :turn_complete, stop_reason: "end_turn"})
    result = finalize(state, :success)

    emit(state, %{
      type: :result,
      text: final_text,
      thinking: state.thinking_text,
      usage: result.usage
    })

    record_transcript(state, %{type: :result, text: final_text})
    reply(state, {:ok, result})
    {:stop, :normal, state}
  end

  # ── Tool dispatch ────────────────────────────────────────────────────────

  defp dispatch_tool(state, %{"name" => name, "input" => input}) do
    ctx = %{
      cwd: state.cwd,
      permission_mode: state.permission_mode,
      run_id: Keyword.get(state.opts, :run_id),
      phase_id: Keyword.get(state.opts, :phase_id),
      session_id: state.session_id,
      mcp_tool_name: if(String.starts_with?(name, "mcp__"), do: name)
    }

    approval_opts =
      case Keyword.get(state.opts, :on_approval) do
        nil -> []
        cb -> [on_approval: cb]
      end

    with {:allow, after_approval} <-
           normalise_approval(
             Crucible.ElixirSdk.Approval.decide(name, input, ctx, approval_opts),
             input
           ),
         {:allow, effective_input} <-
           Crucible.ElixirSdk.Hook.apply_pre(name, after_approval, ctx) do
      do_dispatch(name, effective_input, ctx)
    else
      {:deny, reason} -> "Tool call denied: #{reason}"
    end
  end

  defp normalise_approval(:allow, input), do: {:allow, input}
  defp normalise_approval({:allow, new_input}, _input), do: {:allow, new_input}
  defp normalise_approval({:deny, reason}, _input), do: {:deny, reason}

  defp do_dispatch(name, input, ctx) do
    case ToolRegistry.lookup(name) do
      {:ok, module} ->
        try do
          raw =
            case module.run(input, ctx) do
              {:ok, output} -> to_string(output)
              {:error, reason} -> "Error: #{inspect(reason)}"
            end

          Crucible.ElixirSdk.Hook.apply_post(name, input, raw, ctx)
        rescue
          e -> "Error: #{Exception.message(e)}"
        end

      :error ->
        "Error: tool '#{name}' is not registered"
    end
  end

  # ── Downshifting, course correction, pending injection ──────────────────

  defp maybe_downshift(state) do
    if Keyword.get(state.opts, :downshift?, true) and
         quota_exhausted?(state.model) and
         Map.has_key?(@downshift_chain, state.model) do
      new_model = Map.get(@downshift_chain, state.model)

      emit(state, %{
        type: :model_downshift,
        from: state.model,
        to: new_model,
        reason: "quota_exhausted"
      })

      %{state | model: new_model}
    else
      state
    end
  end

  defp quota_exhausted?(model) do
    try do
      Crucible.Router.QuotaTracker.is_model_exhausted?(model)
    rescue
      _ -> false
    catch
      _ -> false
    end
  end

  defp maybe_course_correct(state) do
    case CourseCorrector.analyse(state.tool_call_history) do
      :ok ->
        state

      {:correct, message} ->
        emit(state, %{type: :course_correction, message: message})
        record_transcript(state, %{type: :course_correction, message: message})

        # Fold correction into the last user message's content list to avoid
        # consecutive user-role messages (which the Anthropic API rejects).
        correction_block = %{"type" => "text", "text" => "[SYSTEM COURSE CORRECTION] " <> message}
        messages = append_to_last_user_message(state.messages, correction_block)

        %{state | messages: messages, tool_call_history: []}
    end
  end

  defp append_to_last_user_message([], block) do
    [%{role: "user", content: [block]}]
  end

  defp append_to_last_user_message(messages, block) do
    {leading, [last]} = Enum.split(messages, -1)

    updated_content =
      case last.content do
        blocks when is_list(blocks) -> blocks ++ [block]
        text when is_binary(text) -> [%{"type" => "text", "text" => text}, block]
      end

    leading ++ [%{last | content: updated_content}]
  end

  defp flush_pending_inject(%{pending_inject: []} = state), do: state

  defp flush_pending_inject(state) do
    # Pending injections are user-role messages. If the last message in history
    # is already a user turn, merge injections into it to avoid consecutive
    # user-role messages (Anthropic API rejects these).
    messages =
      Enum.reduce(state.pending_inject, state.messages, fn text, msgs ->
        block = %{"type" => "text", "text" => text}

        case List.last(msgs) do
          %{role: "user"} -> append_to_last_user_message(msgs, block)
          _ -> msgs ++ [%{role: "user", content: [block]}]
        end
      end)

    %{state | messages: messages, pending_inject: []}
  end

  defp maybe_compact(state) do
    if Keyword.get(state.opts, :auto_compact?, true) do
      %{percentage: pct} =
        Crucible.ElixirSdk.ContextUsage.snapshot(state.usage, state.model)

      opts = [
        threshold_pct: Keyword.get(state.opts, :compact_threshold_pct, 80.0),
        keep_recent: Keyword.get(state.opts, :compact_keep_recent, 6),
        api_key: Keyword.get(state.opts, :api_key)
      ]

      case Crucible.ElixirSdk.Compactor.maybe_compact(state.messages, pct, opts) do
        {:compact, new_messages, %{collapsed: n}} ->
          emit(state, %{type: :compaction, collapsed: n, threshold_pct: opts[:threshold_pct]})
          record_transcript(state, %{type: :compaction, collapsed: n})
          %{state | messages: new_messages}

        {:skip, _} ->
          state
      end
    else
      state
    end
  end

  # ── Block / message helpers ─────────────────────────────────────────────

  defp init_block(%{"type" => "text"} = b), do: Map.put(b, "text", "")
  defp init_block(%{"type" => "thinking"} = b), do: Map.put(b, "thinking", "")
  defp init_block(%{"type" => "tool_use"} = b), do: Map.merge(b, %{"input" => ""})
  defp init_block(b), do: b

  defp apply_delta(block, %{"type" => "text_delta", "text" => txt}),
    do: Map.update(block, "text", txt, &(&1 <> txt))

  defp apply_delta(block, %{"type" => "thinking_delta", "thinking" => txt}),
    do: Map.update(block, "thinking", txt, &(&1 <> txt))

  defp apply_delta(block, %{"type" => "input_json_delta", "partial_json" => chunk}),
    do: Map.update(block, "input", chunk, fn existing -> existing <> chunk end)

  defp apply_delta(block, _), do: block

  defp finalize_block(%{"type" => "tool_use", "input" => input} = block) when is_binary(input) do
    parsed =
      case Jason.decode(input) do
        {:ok, json} -> json
        _ -> %{}
      end

    Map.put(block, "input", parsed)
  end

  defp finalize_block(block), do: block

  defp extract_final_text(blocks) do
    blocks
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map_join("", fn {_idx, blk} ->
      case blk do
        %{"type" => "text", "text" => t} -> t
        _ -> ""
      end
    end)
  end

  defp extract_thinking(blocks) do
    blocks
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map_join("", fn {_idx, blk} ->
      case blk do
        %{"type" => "thinking", "thinking" => t} -> t
        _ -> ""
      end
    end)
  end

  defp merge_usage(current, incoming) do
    %{
      input: current.input + Map.get(incoming, "input_tokens", 0),
      output: current.output + Map.get(incoming, "output_tokens", 0),
      cache_read: current.cache_read + Map.get(incoming, "cache_read_input_tokens", 0),
      cache_creation: current.cache_creation + Map.get(incoming, "cache_creation_input_tokens", 0)
    }
  end

  defp maybe_emit_delta(state, %{"type" => "text_delta", "text" => txt}),
    do: emit(state, %{type: :text_delta, text: txt})

  defp maybe_emit_delta(state, %{"type" => "thinking_delta", "thinking" => txt}),
    do: emit(state, %{type: :thinking_delta, thinking: txt})

  defp maybe_emit_delta(_state, _delta), do: :ok

  defp emit_context_usage(state) do
    snap = ContextUsage.snapshot(state.usage, state.model)
    emit(state, Map.put(snap, :type, :context_usage))
  end

  defp emit(state, event), do: send(state.subscriber, {:crucible_sdk_event, event})

  defp emit_and_record(state, event) do
    emit(state, event)
    record_transcript(state, event)
  end

  defp record_transcript(%{session_id: sid}, event) when is_binary(sid) do
    try do
      Transcript.append(sid, event)
    catch
      _kind, _err -> :ok
    end
  end

  defp record_transcript(_, _), do: :ok

  defp reply(%{caller: nil}, _msg), do: :ok
  defp reply(%{caller: caller}, msg), do: GenServer.reply(caller, msg)

  defp finalize(state, status) do
    %{
      status: status,
      text: state.final_text,
      thinking: state.thinking_text,
      model: state.model,
      initial_model: state.initial_model,
      turns: state.turn,
      tool_calls: state.tool_calls,
      usage: state.usage,
      session_id: state.session_id
    }
  end

  defp abort_stream(%{client_ref: nil}), do: :ok
  defp abort_stream(%{client_ref: ref}), do: Client.abort(ref)

  defp truncate(s, max) when is_binary(s) and byte_size(s) > max,
    do: binary_part(s, 0, max) <> "\n… (truncated)"

  defp truncate(s, _max), do: to_string(s)

  # ── Setup helpers ────────────────────────────────────────────────────────

  defp generate_session_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end

  defp resolve_tools(opts, agent_def) do
    agent_tools = agent_def && agent_def.tools
    opt_tools = Keyword.get(opts, :tools)

    case {opt_tools, agent_tools} do
      {nil, nil} -> ToolRegistry.all()
      {nil, names} -> ToolRegistry.pick(names)
      {:all, _} -> ToolRegistry.all()
      {names, _} when is_list(names) -> ToolRegistry.pick(names)
    end
  end

  defp effective_system(opts, agent_def) do
    case {Keyword.get(opts, :system), agent_def && agent_def.system_prompt} do
      {nil, nil} -> nil
      {user_sys, nil} -> user_sys
      {nil, agent_sys} -> agent_sys
      {user_sys, agent_sys} -> agent_sys <> "\n\n" <> user_sys
    end
  end

  defp build_initial_messages(opts, _agent_def) do
    knowledge_messages = build_knowledge_messages(Keyword.get(opts, :knowledge_sources, []))

    case Keyword.get(opts, :resume_session_id) do
      nil ->
        prompt = Keyword.fetch!(opts, :prompt)
        merge_knowledge_and_prompt(knowledge_messages, prompt)

      sid when is_binary(sid) ->
        base = rebuild_from_transcript(sid)
        continuation = Keyword.get(opts, :prompt)

        if continuation do
          base ++ merge_knowledge_and_prompt(knowledge_messages, continuation)
        else
          base
        end
    end
  end

  # Merge knowledge injection messages with the user prompt, ensuring valid
  # Anthropic API message ordering (strict alternating assistant/user roles).
  # Knowledge injections end on a user-role message (tool_result), so the
  # actual prompt must be folded into that last user message's content list
  # rather than appended as a separate user message.
  defp merge_knowledge_and_prompt([], prompt) do
    [%{role: "user", content: prompt}]
  end

  defp merge_knowledge_and_prompt(knowledge_messages, prompt) do
    {leading, [last]} = Enum.split(knowledge_messages, -1)

    # Last message is a user-role tool_result — append the prompt text to its content list
    merged_content =
      case last.content do
        blocks when is_list(blocks) ->
          blocks ++ [%{"type" => "text", "text" => prompt}]

        text when is_binary(text) ->
          [%{"type" => "text", "text" => text}, %{"type" => "text", "text" => prompt}]
      end

    leading ++ [%{last | content: merged_content}]
  end

  defp build_knowledge_messages([]), do: []

  defp build_knowledge_messages(sources) when is_list(sources) do
    messages = Crucible.Context.KnowledgeInjector.build_injections(sources)

    if messages != [] do
      Logger.debug(
        "KnowledgeInjector: injected #{div(length(messages), 2)} sources into conversation"
      )
    end

    messages
  end

  defp rebuild_from_transcript(session_id) do
    path = Path.join(Transcript.base_dir(), "#{session_id}.jsonl")

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(&Jason.decode!/1)
      |> Enum.reduce([], &reduce_transcript_entry/2)
    else
      []
    end
  rescue
    _ -> []
  end

  defp reduce_transcript_entry(%{"type" => "tool_call"} = e, acc) do
    acc ++
      [
        %{
          role: "assistant",
          content: [
            %{
              "type" => "tool_use",
              "id" => e["tool_use_id"] || "restored",
              "name" => e["name"],
              "input" => e["input"] || %{}
            }
          ]
        }
      ]
  end

  defp reduce_transcript_entry(%{"type" => "tool_result"} = e, acc) do
    acc ++
      [
        %{
          role: "user",
          content: [
            %{
              "type" => "tool_result",
              "tool_use_id" => e["tool_use_id"] || "restored",
              "content" => e["output"] || ""
            }
          ]
        }
      ]
  end

  defp reduce_transcript_entry(_other, acc), do: acc

  defp cacheable_system(nil, _), do: nil
  defp cacheable_system(text, false), do: text

  defp cacheable_system(text, true) when is_binary(text) and byte_size(text) > 1024 do
    # Wrap in a single text block with cache_control — Anthropic caches
    # this prefix across requests in the 5-minute TTL window.
    [%{type: "text", text: text, cache_control: %{type: "ephemeral"}}]
  end

  defp cacheable_system(text, _), do: text

  defp thinking_config(%{thinking_budget: nil}), do: nil

  defp thinking_config(%{thinking_budget: budget}) when is_integer(budget) and budget > 0,
    do: %{type: "enabled", budget_tokens: budget}

  defp thinking_config(_), do: nil

  defp tool_schemas(tools) do
    Enum.map(tools, fn
      {_name, %{input_schema: _} = schema_map} -> schema_map
      {_name, module} when is_atom(module) -> module.schema()
    end)
  end
end
