defmodule Crucible.ElixirSdk.CourseCorrector do
  @moduledoc """
  Detects in-turn tool-use loops and generates a steering message to inject
  back into the conversation.

  Rules (keep simple; match the TS bridge's heuristics):

    * Same tool + same input called 3 times in the last 5 tool calls →
      suggest a different strategy.
    * Bash command with the same command string called 3+ times in a row →
      mention that the command keeps being re-run.
    * Edit with identical old_string / new_string called 2+ times →
      flag that the edit already succeeded.

  Returns `{:correct, message_to_inject}` or `:ok`. Callers append the
  message as a user turn before the next API call.
  """

  @type tool_call :: %{name: String.t(), input: map()}

  @window 5
  @min_repeats 3

  @doc "Analyse the last N tool calls; return `:ok` or a correction message."
  @spec analyse([tool_call()]) :: :ok | {:correct, String.t()}
  def analyse(tool_calls) when is_list(tool_calls) do
    recent = Enum.take(tool_calls, -@window)

    cond do
      bash_loop?(recent) ->
        {:correct,
         "You've run the same bash command " <>
           "#{bash_count(recent)} times in a row without changing approach. " <>
           "Try a different command, inspect a different file, or explain why you're stuck."}

      identical_edit?(recent) ->
        {:correct,
         "The identical Edit call has been attempted twice. The first one likely " <>
           "succeeded — don't re-apply it. Inspect the file to verify, then move on."}

      repeated_tool_input?(recent) ->
        {:correct,
         "You've called the same tool with the same input #{@min_repeats}+ times. " <>
           "Switch strategy: try a different tool, different arguments, or explain your plan first."}

      true ->
        :ok
    end
  end

  # ── rule helpers ─────────────────────────────────────────────────────────

  defp bash_loop?(calls) do
    bashes = Enum.filter(calls, &(&1.name == "Bash"))
    length(bashes) >= @min_repeats and same_field?(bashes, "command")
  end

  defp bash_count(calls), do: Enum.count(calls, &(&1.name == "Bash"))

  defp identical_edit?(calls) do
    edits = Enum.filter(calls, &(&1.name == "Edit"))

    length(edits) >= 2 and same_field?(edits, "old_string") and
      same_field?(edits, "new_string") and same_field?(edits, "file_path")
  end

  defp repeated_tool_input?(calls) do
    grouped = Enum.group_by(calls, fn c -> {c.name, normalise(c.input)} end)
    Enum.any?(grouped, fn {_k, v} -> length(v) >= @min_repeats end)
  end

  defp same_field?(calls, field) do
    values = Enum.map(calls, fn c -> Map.get(c.input, field) end)
    length(Enum.uniq(values)) == 1
  end

  defp normalise(input) when is_map(input) do
    input |> Map.to_list() |> Enum.sort() |> :erlang.phash2()
  end

  defp normalise(_), do: 0
end
