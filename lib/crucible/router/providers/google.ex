defmodule Crucible.Router.Providers.Google do
  @moduledoc "Gemini via `generativelanguage.googleapis.com`."

  @behaviour Crucible.Router.Provider

  alias Crucible.Router.CostTable

  @default_timeout_ms 120_000
  @default_base_url "https://generativelanguage.googleapis.com"

  @impl true
  def name, do: "google"

  @impl true
  def request(model_id, request) do
    start = System.monotonic_time(:millisecond)

    case api_key() do
      "" ->
        {:error, :missing_api_key}

      key ->
        body = build_body(request)
        url = endpoint() <> "/v1beta/models/#{model_id}:generateContent?key=#{key}"

        case Req.post(url,
               json: body,
               headers: [{"content-type", "application/json"}],
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
  end

  @impl true
  def health_check,
    do: match?({:ok, _}, request("gemini-2.5-flash", %{prompt: "ping", max_tokens: 1}))

  # ── helpers ─────────────────────────────────────────────────────────────

  defp api_key do
    System.get_env("GOOGLE_API_KEY") ||
      Application.get_env(:crucible, :google_api_key) ||
      ""
  end

  defp endpoint, do: Application.get_env(:crucible, :google_base_url, @default_base_url)

  defp build_body(request) do
    base = %{
      contents: [
        %{parts: [%{text: Map.get(request, :prompt, "")}]}
      ],
      generationConfig: %{
        maxOutputTokens: Map.get(request, :max_tokens, 4096)
      }
    }

    base =
      case Map.get(request, :temperature) do
        nil -> base
        t -> put_in(base, [:generationConfig, :temperature], t)
      end

    case Map.get(request, :system_prompt) do
      nil ->
        base

      sys when is_binary(sys) ->
        Map.put(base, :systemInstruction, %{parts: [%{text: sys}]})
    end
  end

  defp shape_response(model_id, data, start) do
    text =
      data
      |> get_in(["candidates", Access.at(0), "content", "parts"])
      |> case do
        nil -> ""
        parts -> Enum.map_join(parts, "", &Map.get(&1, "text", ""))
      end

    usage = Map.get(data, "usageMetadata", %{})
    input = Map.get(usage, "promptTokenCount", 0)
    output = Map.get(usage, "candidatesTokenCount", 0)

    %{
      text: text,
      model_id: model_id,
      provider: "google",
      input_tokens: input,
      output_tokens: output,
      cache_read_tokens: 0,
      cache_creation_tokens: 0,
      cost_usd: CostTable.estimate_cost(model_id, input, output),
      latency_ms: System.monotonic_time(:millisecond) - start
    }
  end
end
