defmodule Crucible.Router.Strategy do
  @moduledoc """
  Maps complexity scores to a {model, provider, reason} routing decision.

  Three built-in strategies:

    * `:cost` — cheapest model that can plausibly handle the task
    * `:quality` — best-quality model within reason (Opus for hard tasks)
    * `:speed` — fastest model (prefers low-latency providers)

  Routing profiles (`:deep_reasoning`, `:throughput`, `:verification`,
  `:scout`, `:yolo_classifier`) are higher-level aliases for the raw
  strategies plus implied complexity biases.
  """

  @type decision :: %{model_id: String.t(), provider: String.t(), reason: String.t()}
  @type strategy :: :cost | :quality | :speed
  @type routing_profile ::
          :deep_reasoning | :throughput | :verification | :scout | :yolo_classifier

  @cost %{
    "1-2" => %{
      model_id: "claude-haiku-4-5-20251001",
      provider: "anthropic",
      reason: "Trivial task: Haiku is cheapest for classification/quick questions"
    },
    "3-4" => %{
      model_id: "gemini-2.5-flash",
      provider: "google",
      reason: "Simple task: Gemini Flash is cheapest for summarization/general work"
    },
    "5-6" => %{
      model_id: "MiniMax-M2",
      provider: "minimax",
      reason: "Coding task: MiniMax M2 is cost-efficient for implementation and tool-calling"
    },
    "7-8" => %{
      model_id: "claude-sonnet-4-5-20250929",
      provider: "anthropic",
      reason: "Complex task: Sonnet provides strong code review and debugging capabilities"
    },
    "9-10" => %{
      model_id: "claude-opus-4-7",
      provider: "anthropic",
      reason: "Architecture/reasoning: Opus 4.7 provides the highest quality for complex decisions"
    }
  }

  @quality %{
    "1-2" => %{
      model_id: "claude-haiku-4-5-20251001",
      provider: "anthropic",
      reason: "Trivial: Haiku is sufficient quality for simple lookups"
    },
    "3-4" => %{
      model_id: "claude-sonnet-4-5-20250929",
      provider: "anthropic",
      reason: "Quality mode: Sonnet for even simple tasks to maximize output quality"
    },
    "5-6" => %{
      model_id: "claude-sonnet-4-5-20250929",
      provider: "anthropic",
      reason: "Quality mode: Sonnet for coding tasks to maximize correctness"
    },
    "7-8" => %{
      model_id: "claude-opus-4-7",
      provider: "anthropic",
      reason: "Quality mode: Opus 4.7 for complex tasks to maximize reasoning quality"
    },
    "9-10" => %{
      model_id: "claude-opus-4-7",
      provider: "anthropic",
      reason: "Quality mode: Opus 4.7 for architecture decisions, maximum capability"
    }
  }

  @speed %{
    "1-2" => %{
      model_id: "claude-haiku-4-5-20251001",
      provider: "anthropic",
      reason: "Speed: Haiku has fastest time-to-first-token"
    },
    "3-4" => %{
      model_id: "gemini-2.5-flash",
      provider: "google",
      reason: "Speed: Gemini Flash has very fast inference"
    },
    "5-6" => %{
      model_id: "MiniMax-M2",
      provider: "minimax",
      reason: "Speed: MiniMax M2 is 2x faster than Sonnet for coding"
    },
    "7-8" => %{
      model_id: "claude-sonnet-4-5-20250929",
      provider: "anthropic",
      reason: "Speed: Sonnet balances capability with reasonable latency"
    },
    "9-10" => %{
      model_id: "claude-opus-4-7",
      provider: "anthropic",
      reason: "Speed: Opus 4.7 is required for this complexity, no faster alternative"
    }
  }

  @doc "Select a route given a complexity score and strategy."
  @spec select(pos_integer(), strategy()) :: decision()
  def select(complexity, strategy \\ :cost) do
    bucket = bucket_for(complexity)

    case strategy do
      :quality -> Map.fetch!(@quality, bucket)
      :speed -> Map.fetch!(@speed, bucket)
      _ -> Map.fetch!(@cost, bucket)
    end
  end

  @doc "Resolve a routing profile alias to the underlying strategy."
  @spec resolve_profile(routing_profile()) :: strategy()
  def resolve_profile(:deep_reasoning), do: :quality
  def resolve_profile(:throughput), do: :cost
  def resolve_profile(:verification), do: :quality
  def resolve_profile(:scout), do: :speed
  def resolve_profile(:yolo_classifier), do: :cost
  def resolve_profile(_), do: :cost

  defp bucket_for(c) when c <= 2, do: "1-2"
  defp bucket_for(c) when c <= 4, do: "3-4"
  defp bucket_for(c) when c <= 6, do: "5-6"
  defp bucket_for(c) when c <= 8, do: "7-8"
  defp bucket_for(_), do: "9-10"
end
