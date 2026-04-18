defmodule Crucible.Router do
  @moduledoc """
  Main entry point for Crucible's model router.

  Steps on every call:

    1. Classify the task (complexity 1-10) — unless a hint / profile is given.
    2. Select a route via `Strategy.select/2` (cost / quality / speed) or
       `Strategy.resolve_profile/1` (deep_reasoning / throughput / …).
    3. If the primary provider is quota-exhausted, degrade immediately.
    4. Call the primary provider. On transient failure, cycle through the
       fallback chain (cheapest → most expensive), honouring circuit
       breakers.
    5. Return a `RouterResponse` with cost + safety-check output.

  The tool-use / streaming / SDK path lives in `Crucible.ElixirSdk`; this
  module is for quick, single-turn LLM calls: plan generation, summaries,
  KPI writeups, YOLO classifiers, etc.
  """

  require Logger

  alias Crucible.Router.{Classifier, CostTable, QuotaTracker, Strategy}

  @fallback_order ["ollama", "google", "minimax", "anthropic"]

  @providers %{
    "anthropic" => Crucible.Router.Providers.Anthropic,
    "google" => Crucible.Router.Providers.Google,
    "minimax" => Crucible.Router.Providers.MiniMax,
    "ollama" => Crucible.Router.Providers.Ollama
  }

  @type request :: %{
          required(:prompt) => String.t(),
          optional(:system_prompt) => String.t() | nil,
          optional(:max_tokens) => pos_integer(),
          optional(:temperature) => float() | nil,
          optional(:complexity_hint) => pos_integer(),
          optional(:strategy) => Strategy.strategy(),
          optional(:routing_profile) => Strategy.routing_profile(),
          optional(:force_model) => String.t(),
          optional(:force_provider) => String.t(),
          optional(:cache_system) => boolean(),
          optional(:timeout_ms) => pos_integer()
        }

  @type response :: %{
          text: String.t(),
          model_id: String.t(),
          provider: String.t(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          cache_creation_tokens: non_neg_integer(),
          cost_usd: float(),
          latency_ms: non_neg_integer(),
          classification: map(),
          route: map(),
          degraded?: boolean()
        }

  @doc "Route a single LLM request. Returns `{:ok, response}` or `{:error, reason}`."
  @spec route(request()) :: {:ok, response()} | {:error, term()}
  def route(request) when is_map(request) do
    classification = classify(request)
    route = choose_route(request, classification)

    primary_provider = route.provider
    primary_exhausted? = QuotaTracker.provider_exhausted?(primary_provider)

    case attempt_primary(primary_exhausted?, request, route) do
      {:ok, resp} ->
        {:ok, enrich(resp, classification, route, false)}

      {:error, _reason} ->
        case try_fallbacks(request, primary_provider) do
          {:ok, resp, fallback_route} ->
            {:ok, enrich(resp, classification, fallback_route, true)}

          {:error, reason} ->
            {:error, {:all_providers_failed, reason}}
        end
    end
  end

  @doc "Classify a task without actually running it (useful for UI previews)."
  @spec classify(request()) :: map()
  def classify(%{complexity_hint: hint} = req),
    do: Classifier.classify(Map.get(req, :prompt, ""), hint)

  def classify(req), do: Classifier.classify(Map.get(req, :prompt, ""), nil)

  @doc "Resolve a request to its route without calling the provider."
  @spec choose_route(request(), map()) :: map()
  def choose_route(%{force_model: model} = req, _classification) do
    provider =
      Map.get(req, :force_provider) ||
        (CostTable.get(model) && CostTable.get(model).provider) ||
        "anthropic"

    %{model_id: model, provider: provider, reason: "forced to #{model}"}
  end

  def choose_route(request, classification) do
    strategy =
      cond do
        profile = Map.get(request, :routing_profile) ->
          Strategy.resolve_profile(profile)

        s = Map.get(request, :strategy) ->
          s

        true ->
          :cost
      end

    Strategy.select(classification.complexity, strategy)
  end

  @doc "Provider registry map (used by tests + LiveView)."
  def providers, do: @providers

  # ── internals ──────────────────────────────────────────────────────────

  defp attempt_primary(true, _request, route) do
    Logger.info("Router: primary #{route.provider} exhausted — skipping to fallback")
    {:error, :quota_exhausted}
  end

  defp attempt_primary(false, request, route) do
    call_provider(route.provider, route.model_id, request)
  end

  defp try_fallbacks(request, exclude_provider) do
    @fallback_order
    |> Enum.reject(&(&1 == exclude_provider))
    |> Enum.reject(&QuotaTracker.provider_exhausted?/1)
    |> Enum.find_value({:error, :no_fallback}, fn provider ->
      model = cheapest_for(provider)

      case call_provider(provider, model, request) do
        {:ok, resp} ->
          {:ok, resp,
           %{
             model_id: model,
             provider: provider,
             reason: "fallback via #{provider}"
           }}

        {:error, _} ->
          false
      end
    end)
  end

  defp call_provider(name, model_id, request) do
    case Map.get(@providers, name) do
      nil ->
        {:error, {:unknown_provider, name}}

      module ->
        case module.request(model_id, request) do
          {:ok, resp} ->
            QuotaTracker.record_success(name)
            {:ok, resp}

          {:error, reason} = err ->
            if rate_limited?(reason), do: QuotaTracker.record_exhausted(name)
            err
        end
    end
  end

  defp rate_limited?({:http_error, 429, _}), do: true
  defp rate_limited?({:http_error, 529, _}), do: true
  defp rate_limited?(_), do: false

  defp cheapest_for(provider) do
    CostTable.models()
    |> Map.values()
    |> Enum.filter(&(&1.provider == provider))
    |> Enum.sort_by(fn m -> m.pricing.input_per_million end)
    |> List.first()
    |> case do
      nil -> nil
      %{id: id} -> id
    end
  end

  defp enrich(resp, classification, route, degraded?) do
    resp
    |> Map.put(:classification, classification)
    |> Map.put(:route, route)
    |> Map.put(:degraded?, degraded?)
  end
end
