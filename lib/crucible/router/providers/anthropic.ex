defmodule Crucible.Router.Providers.Anthropic do
  @moduledoc """
  One-shot Messages API call (non-streaming) for the Anthropic provider.

  For streaming + tool-use the SDK path in `Crucible.ElixirSdk` handles it;
  this module is the router's quick path for plan generation, summaries,
  and KPI queries that don't need a tool loop.
  """

  @behaviour Crucible.Router.Provider

  alias Crucible.Router.CostTable

  @api_version "2023-06-01"
  @default_timeout_ms 120_000
  @default_base_url "https://api.anthropic.com"

  @impl true
  def name, do: "anthropic"

  @impl true
  def request(model_id, request) do
    start = System.monotonic_time(:millisecond)
    api_key = api_key()

    body = build_body(model_id, request)
    headers = build_headers(api_key)

    case Req.post(endpoint() <> "/v1/messages",
           json: body,
           headers: headers,
           receive_timeout: Map.get(request, :timeout_ms, @default_timeout_ms)
         ) do
      {:ok, %Req.Response{status: 200, body: data}} ->
        {:ok, shape_response(model_id, data, start)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, inspect(body, limit: 10)}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  @impl true
  def health_check do
    case request("claude-haiku-4-5-20251001", %{prompt: "ping", max_tokens: 1}) do
      {:ok, _} -> true
      _ -> false
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp api_key do
    System.get_env("ANTHROPIC_API_KEY") ||
      Application.get_env(:crucible, :anthropic_api_key) ||
      ""
  end

  defp endpoint,
    do: Application.get_env(:crucible, :anthropic_base_url, @default_base_url)

  defp build_body(model_id, request) do
    %{
      model: model_id,
      max_tokens: Map.get(request, :max_tokens, 4096),
      messages: [%{role: "user", content: Map.get(request, :prompt, "")}]
    }
    |> maybe_put(:system, system_value(request))
    |> maybe_put(:temperature, Map.get(request, :temperature))
  end

  defp system_value(%{system_prompt: nil}), do: nil

  defp system_value(%{system_prompt: sys, cache_system: true}) when is_binary(sys) do
    [%{type: "text", text: sys, cache_control: %{type: "ephemeral"}}]
  end

  defp system_value(%{system_prompt: sys}) when is_binary(sys), do: sys
  defp system_value(_), do: nil

  defp maybe_put(map, _, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp build_headers(api_key) do
    [
      {"x-api-key", api_key},
      {"anthropic-version", @api_version},
      {"content-type", "application/json"}
    ]
  end

  defp shape_response(model_id, %{"content" => blocks, "usage" => usage}, start) do
    text =
      blocks
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("", & &1["text"])

    input = Map.get(usage, "input_tokens", 0)
    output = Map.get(usage, "output_tokens", 0)
    cache_read = Map.get(usage, "cache_read_input_tokens", 0)
    cache_creation = Map.get(usage, "cache_creation_input_tokens", 0)

    %{
      text: text,
      model_id: model_id,
      provider: "anthropic",
      input_tokens: input,
      output_tokens: output,
      cache_read_tokens: cache_read,
      cache_creation_tokens: cache_creation,
      cost_usd: CostTable.estimate_cost(model_id, input, output, cache_read, cache_creation),
      latency_ms: System.monotonic_time(:millisecond) - start
    }
  end

  defp shape_response(model_id, _, start) do
    %{
      text: "",
      model_id: model_id,
      provider: "anthropic",
      input_tokens: 0,
      output_tokens: 0,
      cache_read_tokens: 0,
      cache_creation_tokens: 0,
      cost_usd: 0.0,
      latency_ms: System.monotonic_time(:millisecond) - start
    }
  end
end
