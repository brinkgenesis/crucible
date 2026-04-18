defmodule Crucible.Router.CostTable do
  @moduledoc """
  Per-model pricing data (USD per million tokens) and context windows.

  Source of truth for the router's cost-aware decisions and for downstream
  cost estimation. Mirror of the upstream `@crucible/router` npm package's
  cost table; keep them in sync when pricing changes.
  """

  @type pricing :: %{
          input_per_million: number(),
          output_per_million: number(),
          cache_read_per_million: number() | nil,
          cache_write_per_million: number() | nil
        }

  @type model :: %{
          id: String.t(),
          provider: String.t(),
          display_name: String.t(),
          pricing: pricing(),
          context_window: pos_integer(),
          max_output: pos_integer()
        }

  @models %{
    "claude-opus-4-6" => %{
      id: "claude-opus-4-6",
      provider: "anthropic",
      display_name: "Claude Opus 4.6",
      pricing: %{
        input_per_million: 15.0,
        output_per_million: 75.0,
        cache_read_per_million: 1.5,
        cache_write_per_million: 18.75
      },
      context_window: 200_000,
      max_output: 32_000
    },
    "claude-sonnet-4-6" => %{
      id: "claude-sonnet-4-6",
      provider: "anthropic",
      display_name: "Claude Sonnet 4.6",
      pricing: %{
        input_per_million: 3.0,
        output_per_million: 15.0,
        cache_read_per_million: 0.3,
        cache_write_per_million: 3.75
      },
      context_window: 200_000,
      max_output: 16_000
    },
    "claude-sonnet-4-5-20250929" => %{
      id: "claude-sonnet-4-5-20250929",
      provider: "anthropic",
      display_name: "Claude Sonnet 4.5",
      pricing: %{
        input_per_million: 3.0,
        output_per_million: 15.0,
        cache_read_per_million: 0.3,
        cache_write_per_million: 3.75
      },
      context_window: 200_000,
      max_output: 16_000
    },
    "claude-haiku-4-5-20251001" => %{
      id: "claude-haiku-4-5-20251001",
      provider: "anthropic",
      display_name: "Claude Haiku 4.5",
      pricing: %{
        input_per_million: 0.8,
        output_per_million: 4.0,
        cache_read_per_million: 0.08,
        cache_write_per_million: 1.0
      },
      context_window: 200_000,
      max_output: 8_192
    },
    "MiniMax-M2" => %{
      id: "MiniMax-M2",
      provider: "minimax",
      display_name: "MiniMax M2",
      pricing: %{
        input_per_million: 0.15,
        output_per_million: 0.6,
        cache_read_per_million: nil,
        cache_write_per_million: nil
      },
      context_window: 204_000,
      max_output: 131_000
    },
    "gemini-2.5-flash" => %{
      id: "gemini-2.5-flash",
      provider: "google",
      display_name: "Gemini 2.5 Flash",
      pricing: %{
        input_per_million: 0.075,
        output_per_million: 0.3,
        cache_read_per_million: nil,
        cache_write_per_million: nil
      },
      context_window: 1_000_000,
      max_output: 8_192
    },
    "local-ollama" => %{
      id: "local-ollama",
      provider: "ollama",
      display_name: "Local (Ollama)",
      pricing: %{
        input_per_million: 0.0,
        output_per_million: 0.0,
        cache_read_per_million: nil,
        cache_write_per_million: nil
      },
      context_window: 128_000,
      max_output: 8_192
    }
  }

  @doc "Returns the full model registry."
  @spec models() :: %{String.t() => model()}
  def models, do: @models

  @doc "Returns the metadata for `model_id` or nil."
  @spec get(String.t()) :: model() | nil
  def get(model_id), do: Map.get(@models, model_id)

  @doc "Estimate the USD cost for a single call given token counts."
  @spec estimate_cost(
          model_id :: String.t(),
          input_tokens :: non_neg_integer(),
          output_tokens :: non_neg_integer(),
          cache_read_tokens :: non_neg_integer(),
          cache_write_tokens :: non_neg_integer()
        ) :: float()
  def estimate_cost(model_id, input_tokens, output_tokens, cache_read_tokens \\ 0, cache_write_tokens \\ 0) do
    case get(model_id) do
      nil ->
        0.0

      %{pricing: p} ->
        input = input_tokens / 1_000_000 * p.input_per_million
        output = output_tokens / 1_000_000 * p.output_per_million
        cr = cache_read_tokens / 1_000_000 * (p.cache_read_per_million || 0.0)
        cw = cache_write_tokens / 1_000_000 * (p.cache_write_per_million || 0.0)
        input + output + cr + cw
    end
  end
end
