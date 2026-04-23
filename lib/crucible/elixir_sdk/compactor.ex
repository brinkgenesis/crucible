defmodule Crucible.ElixirSdk.Compactor do
  @moduledoc """
  Summarise older conversation turns when context usage crosses a threshold.

  Strategy:
    * Keep the first user message (the initial prompt) as-is.
    * Keep the last `keep_recent` turns verbatim.
    * Collapse everything in between into a single summary message by
      calling Haiku once with the condensed text.
    * Return the new messages list and a compact savings report.

  This is a best-effort context management — Anthropic's beta context
  management feature does something similar server-side, but we implement
  it locally so we don't depend on a beta flag.
  """

  alias Crucible.ElixirSdk.Client

  @default_keep_recent 6
  @summarizer_model "claude-haiku-4-5-20251001"
  @summarizer_timeout_ms 60_000

  @type opts :: [
          threshold_pct: float(),
          keep_recent: pos_integer(),
          model: String.t(),
          api_key: String.t()
        ]

  @doc """
  Decide whether to compact. Returns `{:compact, new_messages}` or
  `{:skip, reason}`.
  """
  @spec maybe_compact(
          messages :: [map()],
          context_pct :: float(),
          opts()
        ) ::
          {:compact, [map()], %{collapsed: pos_integer()}} | {:skip, atom()}
  def maybe_compact(messages, context_pct, opts \\ []) do
    threshold = Keyword.get(opts, :threshold_pct, 80.0)

    cond do
      context_pct < threshold ->
        {:skip, :below_threshold}

      length(messages) < 8 ->
        {:skip, :too_few_turns}

      true ->
        compact(messages, opts)
    end
  end

  # ── compaction ─────────────────────────────────────────────────────────

  defp compact(messages, opts) do
    keep_recent = Keyword.get(opts, :keep_recent, @default_keep_recent)

    {prefix, middle, suffix} = split_for_compaction(messages, keep_recent)

    case middle do
      [] ->
        {:skip, :nothing_to_compact}

      middle_msgs ->
        case summarise(middle_msgs, opts) do
          {:ok, summary} ->
            summary_text =
              "[COMPACTED CONTEXT]\n#{length(middle_msgs)} prior turns were summarised to free up context:\n\n#{summary}"

            # Fold the summary into the last user message of the prefix. This
            # preserves strict assistant/user alternation (Anthropic rejects
            # consecutive user-role messages) and keeps any tool_use/tool_result
            # pairing in the prefix intact.
            prefix = append_text_to_last_user(prefix, summary_text)
            new_messages = prefix ++ suffix
            {:compact, new_messages, %{collapsed: length(middle_msgs)}}

          {:error, _reason} ->
            {:skip, :summariser_failed}
        end
    end
  end

  # Prefix = up to and including the first user message that carries the
  # actual user prompt (a text block, or a binary content string). This keeps
  # any leading (assistant tool_use, user tool_result) knowledge-injection
  # pairs paired together inside the prefix instead of splitting them across
  # the summary boundary — which previously orphaned the first tool_use and
  # caused the Anthropic 400 "tool_use without tool_result" error.
  @doc false
  def split_for_compaction(messages, keep_recent) do
    case find_prompt_message_index(messages) do
      nil ->
        # No recognisable prompt message — fall back to the old behaviour.
        case messages do
          [first | rest] ->
            total = length(rest)
            to_keep = min(keep_recent, total)
            middle = Enum.take(rest, total - to_keep)
            tail = Enum.drop(rest, total - to_keep)
            {[first], middle, tail}

          [] ->
            {[], [], []}
        end

      idx ->
        prefix = Enum.take(messages, idx + 1)
        rest = Enum.drop(messages, idx + 1)

        total = length(rest)
        to_keep = min(keep_recent, total)
        middle = Enum.take(rest, total - to_keep)
        suffix = Enum.drop(rest, total - to_keep)

        # If the suffix starts with a user message, its paired assistant
        # tool_use is stuck in the middle — move the user into middle so the
        # suffix opens on an assistant turn.
        {middle, suffix} = pull_leading_user_to_middle(middle, suffix)

        {prefix, middle, suffix}
    end
  end

  defp find_prompt_message_index(messages) do
    Enum.find_index(messages, fn msg ->
      role = Map.get(msg, :role) || Map.get(msg, "role")
      content = Map.get(msg, :content) || Map.get(msg, "content")
      role == "user" and has_text_block?(content)
    end)
  end

  defp has_text_block?(content) when is_binary(content), do: true

  defp has_text_block?(content) when is_list(content) do
    Enum.any?(content, fn
      %{"type" => "text"} -> true
      %{type: "text"} -> true
      _ -> false
    end)
  end

  defp has_text_block?(_), do: false

  defp pull_leading_user_to_middle(middle, [first | rest] = suffix) do
    role = Map.get(first, :role) || Map.get(first, "role")

    if role == "user" do
      pull_leading_user_to_middle(middle ++ [first], rest)
    else
      {middle, suffix}
    end
  end

  defp pull_leading_user_to_middle(middle, []), do: {middle, []}

  @doc false
  def append_text_to_last_user(messages, text) do
    block = %{"type" => "text", "text" => text}

    case Enum.reverse(messages) do
      [last | rev_rest] when is_map(last) ->
        role = Map.get(last, :role) || Map.get(last, "role")

        if role == "user" do
          content_key = if Map.has_key?(last, :content), do: :content, else: "content"
          existing = Map.get(last, content_key)

          merged =
            case existing do
              blocks when is_list(blocks) ->
                blocks ++ [block]

              str when is_binary(str) ->
                [%{"type" => "text", "text" => str}, block]

              _ ->
                [block]
            end

          Enum.reverse([Map.put(last, content_key, merged) | rev_rest])
        else
          # Prefix doesn't end on user — append a fresh user turn carrying the
          # summary. Unusual: callers normally ensure a user-tailed prefix.
          messages ++ [%{role: "user", content: [block]}]
        end

      _ ->
        messages ++ [%{role: "user", content: [block]}]
    end
  end

  defp summarise(middle_msgs, opts) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("ANTHROPIC_API_KEY")

    if is_binary(api_key) and api_key != "" do
      condensed = encode_for_summary(middle_msgs)

      summary_prompt =
        "Summarise the following agent conversation turns in under 400 words. " <>
          "Preserve: key decisions, tool calls and results, files touched, any errors. " <>
          "Drop: chit-chat, repeated reasoning. Write as a concise status update.\n\n" <>
          condensed

      case Client.stream(
             api_key: api_key,
             model: Keyword.get(opts, :model, @summarizer_model),
             messages: [%{role: "user", content: summary_prompt}],
             max_tokens: 1024,
             subscriber: self(),
             timeout_ms: @summarizer_timeout_ms,
             max_retries: 2
           ) do
        {:ok, _ref} -> collect_summary()
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :no_api_key}
    end
  end

  defp encode_for_summary(messages) do
    messages
    |> Enum.map(fn msg ->
      role = Map.get(msg, :role) || Map.get(msg, "role")
      content = Map.get(msg, :content) || Map.get(msg, "content")
      "### #{role}\n" <> render(content)
    end)
    |> Enum.join("\n\n")
    |> String.slice(0, 40_000)
  end

  defp render(content) when is_binary(content), do: content

  defp render(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"type" => "text", "text" => t} -> t
      %{"type" => "tool_use", "name" => n, "input" => i} -> "→ #{n}(#{short_json(i)})"
      %{"type" => "tool_result", "content" => c} -> "← #{String.slice(to_string(c), 0, 500)}"
      %{"type" => "thinking", "thinking" => t} -> "(thinking) #{String.slice(t, 0, 200)}"
      _ -> ""
    end)
  end

  defp render(_), do: ""

  defp short_json(input) when is_map(input) do
    input |> Jason.encode!() |> String.slice(0, 200)
  end

  defp short_json(input), do: inspect(input) |> String.slice(0, 200)

  defp collect_summary(acc \\ "") do
    receive do
      {:crucible_sdk, :content_block_delta,
       %{"delta" => %{"type" => "text_delta", "text" => txt}}} ->
        collect_summary(acc <> txt)

      {:crucible_sdk, :done, _} ->
        {:ok, acc}

      {:crucible_sdk, :error, reason} ->
        {:error, reason}

      _ ->
        collect_summary(acc)
    after
      @summarizer_timeout_ms -> {:error, :timeout}
    end
  end
end
