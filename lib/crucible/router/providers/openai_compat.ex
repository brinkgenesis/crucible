defmodule Crucible.Router.Providers.OpenAICompat do
  @moduledoc """
  Shared helper for OpenAI-compatible chat/completions providers
  (MiniMax, Ollama, TogetherAI, OpenRouter, etc.).

  A host provider module delegates to `send/3` with its own base URL + API
  key accessor. Requests and responses follow the OpenAI schema.
  """

  alias Crucible.Router.CostTable

  @default_timeout_ms 120_000

  @doc false
  def request(model_id, request, provider_opts) do
    start = System.monotonic_time(:millisecond)
    base_url = Keyword.fetch!(provider_opts, :base_url)
    api_key = Keyword.get(provider_opts, :api_key, "")
    provider_name = Keyword.fetch!(provider_opts, :provider_name)

    body = build_body(model_id, request)

    headers =
      [{"content-type", "application/json"}]
      |> maybe_add_auth(api_key)

    case Req.post(base_url <> "/chat/completions",
           json: body,
           headers: headers,
           receive_timeout: Map.get(request, :timeout_ms, @default_timeout_ms)
         ) do
      {:ok, %Req.Response{status: 200, body: data}} ->
        {:ok, shape_response(model_id, provider_name, data, start)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, inspect(body, limit: 10)}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp maybe_add_auth(headers, ""), do: headers
  defp maybe_add_auth(headers, key) when is_binary(key),
    do: [{"authorization", "Bearer " <> key} | headers]

  defp build_body(model_id, request) do
    messages = []

    messages =
      case Map.get(request, :system_prompt) do
        nil -> messages
        "" -> messages
        sys -> messages ++ [%{role: "system", content: sys}]
      end

    messages = messages ++ [%{role: "user", content: Map.get(request, :prompt, "")}]

    %{
      model: model_id,
      messages: messages,
      max_tokens: Map.get(request, :max_tokens, 4096)
    }
    |> maybe_put(:temperature, Map.get(request, :temperature))
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp shape_response(model_id, provider_name, data, start) do
    text =
      data
      |> get_in(["choices", Access.at(0), "message", "content"])
      |> case do
        nil -> ""
        t when is_binary(t) -> t
        _ -> ""
      end

    usage = Map.get(data, "usage") || %{}
    input = Map.get(usage, "prompt_tokens", 0)
    output = Map.get(usage, "completion_tokens", 0)

    %{
      text: text,
      model_id: model_id,
      provider: provider_name,
      input_tokens: input,
      output_tokens: output,
      cache_read_tokens: 0,
      cache_creation_tokens: 0,
      cost_usd: CostTable.estimate_cost(model_id, input, output),
      latency_ms: System.monotonic_time(:millisecond) - start
    }
  end
end
