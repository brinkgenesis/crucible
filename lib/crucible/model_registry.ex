defmodule Crucible.ModelRegistry do
  @moduledoc """
  Native Elixir model registry — mirrors the TypeScript cost-table.ts.
  Provides model metadata, pricing, and provider info without depending on the TS router API.
  """

  @models [
    %{
      id: "claude-opus-4-6",
      provider: "anthropic",
      display_name: "Claude Opus 4.6",
      context_window: 200_000,
      max_output: 32_000,
      input_cost_per_1k: 0.015,
      output_cost_per_1k: 0.075,
      cache_read_per_1k: 0.0015,
      cache_write_per_1k: 0.01875,
      tier: "highest"
    },
    %{
      id: "claude-sonnet-4-6",
      provider: "anthropic",
      display_name: "Claude Sonnet 4.6",
      context_window: 200_000,
      max_output: 16_000,
      input_cost_per_1k: 0.003,
      output_cost_per_1k: 0.015,
      cache_read_per_1k: 0.0003,
      cache_write_per_1k: 0.00375,
      tier: "high"
    },
    %{
      id: "claude-sonnet-4-5-20250929",
      provider: "anthropic",
      display_name: "Claude Sonnet 4.5",
      context_window: 200_000,
      max_output: 16_000,
      input_cost_per_1k: 0.003,
      output_cost_per_1k: 0.015,
      cache_read_per_1k: 0.0003,
      cache_write_per_1k: 0.00375,
      tier: "high"
    },
    %{
      id: "claude-haiku-4-5-20251001",
      provider: "anthropic",
      display_name: "Claude Haiku",
      context_window: 200_000,
      max_output: 8_192,
      input_cost_per_1k: 0.0008,
      output_cost_per_1k: 0.004,
      cache_read_per_1k: 0.00008,
      cache_write_per_1k: 0.001,
      tier: "fast"
    },
    %{
      id: "MiniMax-M2",
      provider: "minimax",
      display_name: "MiniMax M2",
      context_window: 204_000,
      max_output: 131_000,
      input_cost_per_1k: 0.00015,
      output_cost_per_1k: 0.0006,
      tier: "budget"
    },
    %{
      id: "gemini-2.5-flash",
      provider: "google",
      display_name: "Gemini 2.5 Flash",
      context_window: 1_000_000,
      max_output: 8_192,
      input_cost_per_1k: 0.000075,
      output_cost_per_1k: 0.0003,
      tier: "budget"
    },
    %{
      id: "local-ollama",
      provider: "ollama",
      display_name: "Local (Ollama)",
      context_window: 128_000,
      max_output: 8_192,
      input_cost_per_1k: 0.0,
      output_cost_per_1k: 0.0,
      tier: "free"
    }
  ]

  @doc "Returns all models in the registry."
  @spec list_models() :: [map()]
  def list_models, do: @models

  @doc "Returns all unique providers."
  @spec list_providers() :: [map()]
  def list_providers do
    @models
    |> Enum.map(& &1.provider)
    |> Enum.uniq()
    |> Enum.map(fn name ->
      models = Enum.filter(@models, &(&1.provider == name))
      %{name: name, model_count: length(models), status: :available}
    end)
  end

  @doc "Returns a model by ID, or nil."
  @spec get_model(String.t()) :: map() | nil
  def get_model(id), do: Enum.find(@models, &(&1.id == id))

  @doc "Estimates cost for a given model and token counts."
  @spec estimate_cost(String.t(), non_neg_integer(), non_neg_integer()) :: float()
  def estimate_cost(model_id, input_tokens, output_tokens) do
    case get_model(model_id) do
      nil ->
        0.0

      model ->
        model.input_cost_per_1k * input_tokens / 1_000 +
          model.output_cost_per_1k * output_tokens / 1_000
    end
  end

  @doc """
  Returns circuit breaker states from the native ExternalCircuitBreaker.
  Formatted for display in the Router LiveView.
  """
  @spec circuit_states() :: map()
  def circuit_states do
    try do
      Crucible.ExternalCircuitBreaker.status()
      |> Enum.into(%{}, fn {service, cb} ->
        {to_string(service),
         %{
           "state" => to_string(cb.state),
           "failures" => cb.consecutive_failures
         }}
      end)
    rescue
      _ -> %{}
    catch
      :exit, _ -> %{}
    end
  end
end
