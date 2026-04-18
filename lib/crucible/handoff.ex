defmodule Crucible.Handoff do
  @moduledoc """
  Structured handoff section parsing and validation.

  Parses transcript summaries into structured sections (decisions, lessons,
  open questions, next steps) and validates completeness.
  """

  @type sections :: %{
          decisions: [String.t()],
          lessons: [String.t()],
          open_questions: [String.t()],
          next_steps: [String.t()],
          raw: String.t()
        }

  @doc """
  Parse structured sections from a transcript summary.

  Recognizes markdown-style headers or bullet prefixes:
    ## Decisions / **Decisions**: / Decisions made:
    - decision item

  Falls back gracefully: if no structured sections are found,
  the entire text goes into `raw`.
  """
  @spec parse_sections(String.t() | nil) :: sections()
  def parse_sections(nil), do: empty_sections()
  def parse_sections(""), do: empty_sections()

  def parse_sections(text) do
    text
    |> String.split("\n")
    |> Enum.reduce({:raw, empty_sections(), []}, fn line, {current, sections, raw_lines} ->
      trimmed = String.trim(line)
      lower = String.downcase(trimmed)

      cond do
        decision_header?(lower) ->
          {:decisions, sections, raw_lines}

        lesson_header?(lower) ->
          {:lessons, sections, raw_lines}

        open_question_header?(lower) ->
          {:open_questions, sections, raw_lines}

        next_step_header?(lower) ->
          {:next_steps, sections, raw_lines}

        bullet_item?(trimmed) && current != :raw ->
          item = extract_bullet(trimmed)
          {current, append_to_section(sections, current, item), raw_lines}

        trimmed != "" && current != :raw ->
          {current, append_to_section(sections, current, trimmed), raw_lines}

        trimmed != "" ->
          {:raw, sections, [trimmed | raw_lines]}

        true ->
          {current, sections, raw_lines}
      end
    end)
    |> then(fn {_current, sections, raw_lines} ->
      %{sections | raw: raw_lines |> Enum.reverse() |> Enum.join("\n")}
    end)
  end

  @doc """
  Validate that a handoff has minimum required sections.
  Returns a list of missing section names (empty = valid).
  """
  @spec validate_completeness(sections()) :: [String.t()]
  def validate_completeness(sections) do
    has_any =
      sections.decisions != [] ||
        sections.lessons != [] ||
        sections.open_questions != [] ||
        sections.next_steps != []

    if has_any && sections.next_steps == [] do
      ["next_steps"]
    else
      []
    end
  end

  @doc """
  Returns true if sections contain any structured content.
  """
  @spec has_structured_content?(sections()) :: boolean()
  def has_structured_content?(sections) do
    sections.decisions != [] ||
      sections.lessons != [] ||
      sections.open_questions != [] ||
      sections.next_steps != []
  end

  # --- Header detection ---

  defp decision_header?(lower) do
    Regex.match?(~r/^(\#{1,3}\s+)?(\*\*)?decisions?(\s+made)?(\*\*)?:?$/, lower) ||
      String.starts_with?(lower, "decisions made") ||
      String.starts_with?(lower, "decisions:")
  end

  defp lesson_header?(lower) do
    Regex.match?(~r/^(\#{1,3}\s+)?(\*\*)?lessons?(\s+learned)?(\*\*)?:?$/, lower) ||
      String.starts_with?(lower, "lessons learned") ||
      String.starts_with?(lower, "lessons:")
  end

  defp open_question_header?(lower) do
    Regex.match?(~r/^(\#{1,3}\s+)?(\*\*)?open\s+questions?(\*\*)?:?$/, lower) ||
      String.starts_with?(lower, "open questions") ||
      String.starts_with?(lower, "blockers")
  end

  defp next_step_header?(lower) do
    Regex.match?(~r/^(\#{1,3}\s+)?(\*\*)?next\s+steps?(\*\*)?:?$/, lower) ||
      String.starts_with?(lower, "next steps") ||
      String.starts_with?(lower, "recommended")
  end

  defp bullet_item?(line) do
    Regex.match?(~r/^\s*[-*]\s+.+/, line)
  end

  defp extract_bullet(line) do
    line
    |> String.replace(~r/^\s*[-*]\s+/, "")
    |> String.trim()
  end

  defp empty_sections do
    %{decisions: [], lessons: [], open_questions: [], next_steps: [], raw: ""}
  end

  defp append_to_section(sections, key, value) do
    Map.update!(sections, key, &(&1 ++ [value]))
  end
end
