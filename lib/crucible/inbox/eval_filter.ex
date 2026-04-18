defmodule Crucible.Inbox.EvalFilter do
  @moduledoc """
  Inbox triage — LLM-based evaluation and scoring of inbox items.

  Port of `lib/inbox/eval-filter.ts` from infra.

  Evaluates items on 5 dimensions (actionability, relevance, specificity,
  novelty, strategic_value), applies label-specific weights, and assigns
  a bucket (auto-promote, review, low-priority, dismiss).

  Public API:
    - `evaluate/1` — evaluate a single item via router at complexity 2
    - `evaluate/2` — evaluate with custom router function
    - `weighted_average/2` — compute weighted score from dimensions + labels
    - `assign_bucket/1` — map a score to a bucket
  """

  require Logger

  # novelty is intentionally excluded — it should be vector-injected, not LLM-scored
  @dimensions ~w(actionability relevance specificity strategic_value)
  @labels ~w(bug-fix feature optimization research tooling competitive-intel infrastructure)

  @thresholds %{
    auto_promote: 7.0,
    human_review: 4.0,
    low_priority: 2.0
  }

  @default_weights %{
    "actionability" => 1.0,
    "relevance" => 1.0,
    "specificity" => 1.0,
    "novelty" => 1.0,
    "strategic_value" => 1.0
  }

  @label_weights %{
    "research" => %{
      "actionability" => 0.5,
      "specificity" => 0.5,
      "strategic_value" => 2.0,
      "novelty" => 1.5
    },
    "competitive-intel" => %{
      "actionability" => 0.3,
      "specificity" => 0.5,
      "strategic_value" => 2.5,
      "relevance" => 1.5
    },
    "optimization" => %{"actionability" => 1.0, "specificity" => 1.0, "strategic_value" => 1.5},
    "bug-fix" => %{"actionability" => 1.5, "specificity" => 1.5, "strategic_value" => 0.5}
  }

  @system_prompt """
  You are an inbox triage system. Evaluate the provided item and respond with valid JSON only.
  Score each dimension 0-10. Assign relevant labels. Be concise.\
  """

  @type dimension_score :: %{criterion: String.t(), score: number(), note: String.t()}

  @type eval_result :: %{
          item_id: String.t(),
          dimensions: [dimension_score()],
          labels: [String.t()],
          average_score: float(),
          feedback: String.t(),
          bucket: String.t()
        }

  @doc "Evaluate an inbox item via the model router at complexity 2."
  @spec evaluate(map()) :: {:ok, eval_result()} | {:error, term()}
  def evaluate(item), do: evaluate(item, &default_route/1)

  @doc "Evaluate an inbox item with a custom router function."
  @spec evaluate(map(), (map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, eval_result()} | {:error, term()}
  def evaluate(item, router_fn) when is_function(router_fn, 1) do
    request = %{
      prompt: build_eval_prompt(item),
      system_prompt: @system_prompt,
      complexity_hint: 2,
      strategy: :cost,
      max_tokens: 512
    }

    case router_fn.(request) do
      {:ok, %{text: text}} ->
        case parse_eval(text, item) do
          {:ok, result} -> {:ok, result}
          :error -> {:ok, fallback_eval(item)}
        end

      {:error, reason} ->
        Logger.warning(
          "EvalFilter: evaluation failed for #{inspect(item[:id])}: #{inspect(reason)}"
        )

        {:ok, fallback_eval(item)}
    end
  end

  @doc "Compute weighted average score given dimensions and labels."
  @spec weighted_average([dimension_score()], [String.t()]) :: float()
  def weighted_average([], _labels), do: 0.0

  def weighted_average(dimensions, labels) do
    weights = merge_label_weights(labels)

    {weighted_sum, total_weight} =
      Enum.reduce(dimensions, {0.0, 0.0}, fn dim, {sum, tw} ->
        w = Map.get(weights, dim.criterion, 1.0)
        {sum + dim.score * w, tw + w}
      end)

    if total_weight > 0, do: weighted_sum / total_weight, else: 0.0
  end

  @doc "Assign a bucket based on average score."
  @spec assign_bucket(float()) :: String.t()
  def assign_bucket(score) when score >= 7.0, do: "auto-promote"
  def assign_bucket(score) when score >= 4.0, do: "review"
  def assign_bucket(score) when score >= 2.0, do: "low-priority"
  def assign_bucket(_score), do: "dismiss"

  # --- Private ---

  defp default_route(request), do: Crucible.Router.route(request)

  defp build_eval_prompt(item) do
    title = item[:title] || item["title"] || "Untitled"
    text = item[:original_text] || item["original_text"] || ""
    summary = item[:summary] || item["summary"] || ""

    content = if summary != "", do: summary, else: String.slice(text, 0, 2000)

    """
    Evaluate this inbox item and respond with JSON only:

    Title: #{title}
    Content: #{content}

    Response schema:
    {
      "dimensions": [
        {"criterion": "actionability", "score": 0-10, "note": "brief reason"},
        {"criterion": "relevance", "score": 0-10, "note": "brief reason"},
        {"criterion": "specificity", "score": 0-10, "note": "brief reason"},
        {"criterion": "strategic_value", "score": 0-10, "note": "brief reason"}
      ],
      "labels": ["bug-fix"|"feature"|"optimization"|"research"|"tooling"|"competitive-intel"|"infrastructure"],
      "feedback": "1-sentence summary of evaluation reasoning"
    }\
    """
  end

  defp parse_eval(text, item) do
    with {:ok, json_str} <- extract_json(text),
         {:ok, parsed} <- Jason.decode(json_str),
         {:ok, dimensions} <- parse_dimensions(parsed["dimensions"]),
         labels <- parse_labels(parsed["labels"]) do
      avg = weighted_average(dimensions, labels)

      {:ok,
       %{
         item_id: to_string(item[:id] || item["id"] || "unknown"),
         dimensions: dimensions,
         labels: labels,
         average_score: Float.round(avg, 2),
         feedback: parsed["feedback"] || "",
         bucket: assign_bucket(avg)
       }}
    else
      _ -> :error
    end
  end

  defp extract_json(text) do
    case Regex.run(~r/\{[\s\S]*\}/, text) do
      [json | _] -> {:ok, json}
      _ -> :error
    end
  end

  defp parse_dimensions(nil), do: :error

  defp parse_dimensions(dims) when is_list(dims) do
    parsed =
      Enum.map(dims, fn d ->
        criterion = d["criterion"]
        score = d["score"]
        note = d["note"] || ""

        if criterion in @dimensions and is_number(score) do
          %{criterion: criterion, score: score, note: note}
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if length(parsed) >= 3, do: {:ok, parsed}, else: :error
  end

  defp parse_labels(nil), do: []

  defp parse_labels(labels) when is_list(labels) do
    Enum.filter(labels, &(&1 in @labels))
  end

  defp merge_label_weights(labels) do
    Enum.reduce(labels, @default_weights, fn label, weights ->
      case @label_weights[label] do
        nil ->
          weights

        lw ->
          Map.merge(weights, lw, fn _dim, current, new_val ->
            if abs(new_val - 1.0) > abs(current - 1.0), do: new_val, else: current
          end)
      end
    end)
  end

  defp fallback_eval(item) do
    %{
      item_id: to_string(item[:id] || item["id"] || "unknown"),
      dimensions: Enum.map(@dimensions, &%{criterion: &1, score: 5.0, note: "fallback"}),
      labels: [],
      average_score: 5.0,
      feedback: "Evaluation failed, assigned default score",
      bucket: "review"
    }
  end
end
