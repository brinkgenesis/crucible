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
            summary_msg = %{
              role: "user",
              content:
                "[COMPACTED CONTEXT]\n#{length(middle_msgs)} prior turns were summarised to free up context:\n\n#{summary}"
            }

            new_messages = prefix ++ [summary_msg] ++ suffix
            {:compact, new_messages, %{collapsed: length(middle_msgs)}}

          {:error, _reason} ->
            {:skip, :summariser_failed}
        end
    end
  end

  defp split_for_compaction(messages, keep_recent) do
    case messages do
      [first | rest] ->
        total = length(rest)
        to_keep = min(keep_recent, total)
        middle_count = total - to_keep

        middle = Enum.take(rest, middle_count)
        tail = Enum.drop(rest, middle_count)
        {[first], middle, tail}

      [] ->
        {[], [], []}
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
