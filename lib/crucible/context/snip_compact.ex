defmodule Crucible.Context.SnipCompact do
  @moduledoc """
  Deterministic, LLM-free compaction for large tool outputs mid-conversation.

  This is the "micro" tier of context compression — it replaces bulky
  `tool_result` payloads (file reads, searches, command stdout) with a
  short head/tail snippet plus metadata. It sits alongside two other
  layers:

    * `Crucible.ContextManager` — per-run full-conversation summarisation
      (macro tier, calls the router on a cheap model).
    * `Crucible.ElixirSdk.Compactor` — mid-stream turn collapsing
      (meso tier, calls Haiku directly).

  SnipCompact does not call any model. It uses tool-specific heuristics
  so savings are cheap and predictable. Exempt tools (`edit_file`,
  `write_file`, `git_commit`, `memory_store`) always pass through
  unchanged — their outputs are small and semantically critical.
  Results flagged `is_error: true` also bypass compaction so debugging
  context stays intact.

  Ported from `lib/api-executor/snip-compact.ts` (infra repo).
  """

  require Logger

  # ── configuration ─────────────────────────────────────────────────────

  @compaction_threshold_tokens 500
  @snippet_head_chars 300
  @snippet_tail_chars 200

  @exempt_tools ~w(edit_file write_file git_commit memory_store)

  # ── public types ──────────────────────────────────────────────────────

  @type result :: %{
          content: String.t(),
          compacted: boolean(),
          original_tokens: non_neg_integer(),
          compacted_tokens: non_neg_integer()
        }

  @type tool_result :: %{
          required(:tool_use_id) => String.t(),
          required(:tool_name) => String.t(),
          required(:content) => String.t(),
          optional(:is_error) => boolean()
        }

  # ── public API ────────────────────────────────────────────────────────

  @doc """
  Compact a single tool output if it exceeds the token threshold.

  Returns a map with the (possibly compacted) content plus metadata
  useful for telemetry.
  """
  @spec snip_compact(String.t(), String.t()) :: result()
  def snip_compact(tool_name, content) when is_binary(tool_name) and is_binary(content) do
    original_tokens = estimate_tokens(content)

    cond do
      original_tokens <= @compaction_threshold_tokens ->
        %{
          content: content,
          compacted: false,
          original_tokens: original_tokens,
          compacted_tokens: original_tokens
        }

      tool_name in @exempt_tools ->
        %{
          content: content,
          compacted: false,
          original_tokens: original_tokens,
          compacted_tokens: original_tokens
        }

      true ->
        compacted = compact_by_tool(tool_name, content, original_tokens)
        compacted_tokens = estimate_tokens(compacted)

        %{
          content: compacted,
          compacted: true,
          original_tokens: original_tokens,
          compacted_tokens: compacted_tokens
        }
    end
  end

  @doc """
  Compact every tool result in a list, skipping error outputs.

  Returns `%{results: compacted_list, total_saved: tokens}` so callers
  can emit telemetry or budget adjustments.
  """
  @spec snip_compact_tool_results([tool_result()]) :: %{
          results: [tool_result()],
          total_saved: non_neg_integer()
        }
  def snip_compact_tool_results(results) when is_list(results) do
    {compacted_results, saved} =
      Enum.map_reduce(results, 0, fn entry, acc ->
        cond do
          Map.get(entry, :is_error, false) ->
            {entry, acc}

          true ->
            tool_name = Map.fetch!(entry, :tool_name)
            content = Map.fetch!(entry, :content)
            out = snip_compact(tool_name, content)

            entry = Map.put(entry, :content, out.content)

            if out.compacted do
              {entry, acc + out.original_tokens - out.compacted_tokens}
            else
              {entry, acc}
            end
        end
      end)

    %{results: compacted_results, total_saved: saved}
  end

  @doc """
  Rough token estimator — blends a prose model (~1.3 tokens/word) with a
  code model (~chars/3.3) based on how punctuation-heavy the text is.

  Mirrors `estimateTokens` in the TypeScript api-executor so we stay
  comparable across languages.
  """
  @spec estimate_tokens(String.t()) :: non_neg_integer()
  def estimate_tokens(""), do: 0

  def estimate_tokens(text) when is_binary(text) do
    trimmed = String.trim(text)

    if trimmed == "" do
      0
    else
      words = trimmed |> String.split(~r/\s+/, trim: true) |> length()
      chars = String.length(text)

      code_chars =
        Regex.scan(~r/[{}()\[\];=<>|&!+\-*\/%^~`]/, text)
        |> length()

      code_ratio = min(code_chars / max(chars, 1), 0.3)

      prose_estimate = ceil(words * 1.3)
      code_estimate = ceil(chars / 3.3)

      ceil(prose_estimate * (1 - code_ratio) + code_estimate * code_ratio)
    end
  end

  # ── tool-specific strategies ──────────────────────────────────────────

  defp compact_by_tool("read_file", content, tokens), do: compact_file_read(content, tokens)

  defp compact_by_tool(tool, content, tokens) when tool in ["search_files", "glob_files"],
    do: compact_search_results(content, tokens)

  defp compact_by_tool("run_command", content, tokens),
    do: compact_command_output(content, tokens)

  defp compact_by_tool(_other, content, tokens), do: compact_generic(content, tokens)

  # read_file: if JSON-shaped, surface path/line count + head/tail. Else
  # fall back to generic.
  defp compact_file_read(content, tokens) do
    case Jason.decode(content) do
      {:ok, %{} = parsed} ->
        file_content = Map.get(parsed, "content", content)
        lines = String.split(file_content, "\n")
        line_count = length(lines)

        head = lines |> Enum.take(15) |> Enum.join("\n")
        tail = lines |> Enum.take(-5) |> Enum.join("\n")
        omitted = max(line_count - 20, 0)

        truncated_line =
          if Map.get(parsed, "truncated"), do: "(file was truncated on read)", else: nil

        size_bytes = Map.get(parsed, "size_bytes", "?")
        path = Map.get(parsed, "path", "unknown")

        [
          "[snipCompact: #{tokens} tokens → summary]",
          "File: #{path} (#{line_count} lines, #{size_bytes} bytes)",
          truncated_line,
          "--- first 15 lines ---",
          head,
          "--- ... #{omitted} lines omitted ---",
          "--- last 5 lines ---",
          tail
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      _ ->
        Logger.debug("snip_compact: read_file output not JSON, using generic compaction")
        compact_generic(content, tokens)
    end
  end

  # search/glob: line-based. Keep first 10 + last 5 if >20 matches.
  defp compact_search_results(content, tokens) do
    lines = String.split(content, "\n")
    match_count = length(lines)

    if match_count <= 20 do
      content
    else
      head = lines |> Enum.take(10) |> Enum.join("\n")
      tail = lines |> Enum.take(-5) |> Enum.join("\n")

      [
        "[snipCompact: #{tokens} tokens → summary]",
        "#{match_count} results found. Showing first 10 and last 5:",
        head,
        "--- ... #{match_count - 15} results omitted ---",
        tail
      ]
      |> Enum.join("\n")
    end
  end

  # run_command: char-based head/tail snippet.
  defp compact_command_output(content, tokens) do
    head = binary_slice_safe(content, 0, @snippet_head_chars)
    tail_start = max(byte_size(content) - @snippet_tail_chars, 0)
    tail = binary_slice_safe(content, tail_start, @snippet_tail_chars)

    total_chars = byte_size(content)
    omitted = max(total_chars - @snippet_head_chars - @snippet_tail_chars, 0)

    [
      "[snipCompact: #{tokens} tokens → summary, #{total_chars} chars total]",
      "--- first #{@snippet_head_chars} chars ---",
      head,
      "--- ... #{omitted} chars omitted ---",
      "--- last #{@snippet_tail_chars} chars ---",
      tail
    ]
    |> Enum.join("\n")
  end

  # generic: head + tail + omission marker.
  defp compact_generic(content, tokens) do
    head = binary_slice_safe(content, 0, @snippet_head_chars)
    tail_start = max(byte_size(content) - @snippet_tail_chars, 0)
    tail = binary_slice_safe(content, tail_start, @snippet_tail_chars)

    summary_tokens = estimate_tokens(head <> tail)

    [
      "[snipCompact: #{tokens} tokens → #{summary_tokens} tokens]",
      head,
      "--- ... content omitted (#{byte_size(content)} chars total) ---",
      tail
    ]
    |> Enum.join("\n")
  end

  # ── helpers ───────────────────────────────────────────────────────────

  # binary_part raises on out-of-range slices; this clamps gracefully so
  # callers never have to worry about short inputs.
  defp binary_slice_safe(bin, start, len) when is_binary(bin) do
    size = byte_size(bin)
    start = max(min(start, size), 0)
    len = max(min(len, size - start), 0)
    binary_part(bin, start, len)
  end
end
