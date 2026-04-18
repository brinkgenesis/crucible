defmodule Crucible.ElixirSdk.ContextUsage do
  @moduledoc """
  Coarse context-window utilisation estimator.

  The real Anthropic SDK exposes a `getContextUsage/0` call that walks the
  transport's internal counters. Here we approximate from the usage block
  echoed in each `message_delta` event: cumulative `input_tokens + output_tokens`
  vs the model's window. Good enough for "you're at 78% context" warnings.
  """

  @type snapshot :: %{
          percentage: float(),
          total_tokens: non_neg_integer(),
          max_tokens: non_neg_integer(),
          model: String.t()
        }

  # Mirror Crucible.Router.CostTable — source-of-truth should be the router,
  # but that's a separate package. Kept in sync manually for now.
  @windows %{
    "claude-opus-4-6" => 200_000,
    "claude-sonnet-4-6" => 200_000,
    "claude-sonnet-4-5-20250929" => 200_000,
    "claude-haiku-4-5-20251001" => 200_000,
    "MiniMax-M2" => 204_000,
    "gemini-2.5-flash" => 1_000_000
  }

  @doc "Estimate context window utilisation from current usage + model."
  @spec snapshot(map(), String.t()) :: snapshot()
  def snapshot(usage, model) do
    max = Map.get(@windows, model, 200_000)
    total = Map.get(usage, :input, 0) + Map.get(usage, :output, 0)
    pct = if max > 0, do: total / max * 100.0, else: 0.0

    %{
      percentage: Float.round(pct, 1),
      total_tokens: total,
      max_tokens: max,
      model: model
    }
  end
end
