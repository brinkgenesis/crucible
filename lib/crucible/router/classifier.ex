defmodule Crucible.Router.Classifier do
  @moduledoc """
  Maps an LLM task to a complexity score 1–10.

  1-2  — trivial lookups, classification
  3-4  — general summaries, simple transforms
  5-6  — coding, moderate synthesis
  7-8  — debugging, complex coding, code review
  9-10 — architecture, tradeoff analysis, cross-system design

  The scoring combines an optional user-provided hint with regex-based
  signal matching on the prompt text. The regexes are the same set as the
  upstream TS classifier; keep them aligned when the TS changes.
  """

  @type result :: %{
          complexity: pos_integer(),
          category: String.t(),
          reasoning: String.t()
        }

  @high [
    ~r/architect/i,
    ~r/design\s+(system|api|schema|database)/i,
    ~r/tradeoff/i,
    ~r/trade-off/i,
    ~r/complex\s+reasoning/i,
    ~r/multi.?step\s+plan/i,
    ~r/security\s+(audit|review|analysis)/i,
    ~r/refactor\s+(entire|whole|complete)/i,
    ~r/migration\s+strateg/i
  ]

  @medium_high [
    ~r/debug/i,
    ~r/code\s+review/i,
    ~r/implement.*integrat/i,
    ~r/fix.*bug/i,
    ~r/performance\s+(optim|improv|tun)/i,
    ~r/test.*coverage/i,
    ~r/error\s+handling/i
  ]

  @medium [
    ~r/implement/i,
    ~r/write\s+(code|function|class|module)/i,
    ~r/create\s+(endpoint|api|component)/i,
    ~r/add\s+(feature|functionality)/i,
    ~r/edit\s+(file|code)/i,
    ~r/update/i,
    ~r/coding/i
  ]

  @low [
    ~r/summarize/i,
    ~r/explain/i,
    ~r/describe/i,
    ~r/list/i,
    ~r/format/i,
    ~r/convert/i,
    ~r/translate/i,
    ~r/general/i
  ]

  @trivial [
    ~r/classify/i,
    ~r/yes\s+or\s+no/i,
    ~r/true\s+or\s+false/i,
    ~r/which\s+(one|option)/i,
    ~r/quick\s+question/i,
    ~r/lookup/i
  ]

  @doc "Classify a prompt. If `hint` is in 1..10, it short-circuits the regex analysis."
  @spec classify(String.t(), pos_integer() | nil) :: result()
  def classify(prompt, hint \\ nil) do
    case hint do
      n when is_integer(n) and n >= 1 and n <= 10 ->
        %{complexity: n, category: category(n), reasoning: "User-provided complexity hint: #{n}"}

      _ ->
        score_from_prompt(prompt)
    end
  end

  defp score_from_prompt(prompt) when is_binary(prompt) do
    high = count_matches(prompt, @high)
    mhigh = count_matches(prompt, @medium_high)
    med = count_matches(prompt, @medium)
    low_ = count_matches(prompt, @low)
    triv = count_matches(prompt, @trivial)

    {score, reasoning} =
      cond do
        high > 0 -> {9 + min(high - 1, 1), "Matched high-complexity signals"}
        mhigh > 0 -> {7 + min(mhigh - 1, 1), "Matched medium-high signals"}
        med > 0 -> {5 + min(med - 1, 1), "Matched medium signals"}
        low_ > 0 -> {3 + min(low_ - 1, 1), "Matched low signals"}
        triv > 0 -> {1 + min(triv - 1, 1), "Matched trivial signals"}
        true -> {5, "No signals; default"}
      end

    # Prompt-length heuristic (only when we hadn't matched anything).
    word_count = prompt |> String.split() |> length()

    score =
      cond do
        high + mhigh + med + low_ + triv == 0 and word_count < 10 -> max(score - 1, 1)
        word_count > 500 -> min(score + 1, 10)
        true -> score
      end

    %{complexity: score, category: category(score), reasoning: reasoning}
  end

  defp score_from_prompt(_),
    do: %{complexity: 5, category: "coding", reasoning: "Non-string prompt"}

  defp count_matches(prompt, regexes),
    do: Enum.count(regexes, &Regex.match?(&1, prompt))

  defp category(c) when c >= 9, do: "architecture"
  defp category(c) when c >= 7, do: "complex-coding"
  defp category(c) when c >= 5, do: "coding"
  defp category(c) when c >= 3, do: "general"
  defp category(_), do: "trivial"
end
