defmodule Crucible.RouterHealthReader do
  @moduledoc """
  Native provider health probes aligned with the TypeScript dashboard router checks.
  """

  alias Crucible.Secrets

  @cache_table :crucible_router_health_cache
  @cache_key :provider_health
  @cache_ttl_ms 30_000
  @request_timeout_ms 1_500

  @spec health() :: map()
  def health do
    ensure_cache_table()

    case lookup_cache() do
      {:ok, cached} ->
        cached

      :miss ->
        data = fetch_health()
        put_cache(data)
        data
    end
  end

  defp fetch_health do
    %{
      "anthropic" => anthropic_health?(),
      "google" => google_health?(),
      "minimax" => minimax_health?(),
      "ollama" => ollama_health?()
    }
  end

  defp anthropic_health? do
    with key when is_binary(key) and key != "" <- Secrets.get("ANTHROPIC_API_KEY"),
         {:ok, %{status: status}} when status in 200..299 <-
           Req.post(anthropic_url(),
             headers: [
               {"x-api-key", key},
               {"anthropic-version", "2023-06-01"}
             ],
             json: %{
               "model" => "claude-haiku-4-5-20251001",
               "max_tokens" => 1,
               "messages" => [%{"role" => "user", "content" => "ping"}]
             },
             retry: false,
             receive_timeout: @request_timeout_ms,
             connect_options: [timeout: @request_timeout_ms]
           ) do
      true
    else
      _ -> false
    end
  end

  defp google_health? do
    with key when is_binary(key) and key != "" <- Secrets.get("GOOGLE_API_KEY"),
         {:ok, %{status: status}} when status in 200..299 <-
           Req.post(google_url(key),
             json: %{
               "contents" => [%{"parts" => [%{"text" => "ping"}]}],
               "generationConfig" => %{"maxOutputTokens" => 1}
             },
             retry: false,
             receive_timeout: @request_timeout_ms,
             connect_options: [timeout: @request_timeout_ms]
           ) do
      true
    else
      _ -> false
    end
  end

  defp minimax_health? do
    with key when is_binary(key) and key != "" <- Secrets.get("MINIMAX_API_KEY"),
         {:ok, %{status: status}} when status in 200..299 <-
           Req.post(minimax_url(),
             auth: {:bearer, key},
             json: %{
               "model" => System.get_env("MINIMAX_MODEL") || "MiniMax-M2",
               "messages" => [%{"role" => "user", "content" => "ping"}],
               "max_tokens" => 1
             },
             retry: false,
             receive_timeout: @request_timeout_ms,
             connect_options: [timeout: @request_timeout_ms]
           ) do
      true
    else
      _ -> false
    end
  end

  defp ollama_health? do
    case Req.get(ollama_url(),
           retry: false,
           receive_timeout: @request_timeout_ms,
           connect_options: [timeout: @request_timeout_ms]
         ) do
      {:ok, %{status: status}} when status in 200..299 -> true
      _ -> false
    end
  end

  defp anthropic_url, do: "https://api.anthropic.com/v1/messages"

  defp google_url(api_key) do
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=#{api_key}"
  end

  defp minimax_url do
    base_url =
      System.get_env("MINIMAX_BASE_URL") ||
        "https://api.minimax.io/v1"

    String.trim_trailing(base_url, "/") <> "/chat/completions"
  end

  defp ollama_url do
    case System.get_env("OLLAMA_BASE_URL") do
      nil ->
        "http://localhost:11434/api/tags"

      base_url ->
        base_url
        |> String.trim_trailing("/")
        |> String.replace_suffix("/v1", "")
        |> Kernel.<>("/api/tags")
    end
  end

  defp ensure_cache_table do
    case :ets.whereis(@cache_table) do
      :undefined ->
        :ets.new(@cache_table, [:named_table, :public, read_concurrency: true])

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp lookup_cache do
    case :ets.lookup(@cache_table, @cache_key) do
      [{@cache_key, ts, data}] ->
        if System.system_time(:millisecond) - ts < @cache_ttl_ms do
          {:ok, data}
        else
          :miss
        end

      _ ->
        :miss
    end
  rescue
    _ -> :miss
  end

  defp put_cache(data) do
    :ets.insert(@cache_table, {@cache_key, System.system_time(:millisecond), data})
    :ok
  rescue
    _ -> :ok
  end
end
