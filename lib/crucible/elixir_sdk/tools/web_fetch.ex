defmodule Crucible.ElixirSdk.Tools.WebFetch do
  @moduledoc """
  HTTPS-fetch tool.

  Requests `url`, follows redirects, returns response body (text, markdown,
  or JSON). If `prompt` is supplied, the fetched content is piped through
  a summarization call before being returned.

  Security: HTTPS-only by default (set `CRUCIBLE_ALLOW_HTTP=1` to allow
  plaintext). Response size capped at 1 MiB. Total deadline 30s.
  """

  @behaviour Crucible.ElixirSdk.Tool

  @max_bytes 1_048_576
  @default_timeout_ms 30_000

  @impl true
  def schema do
    %{
      name: "WebFetch",
      description: """
      Fetch a URL and return its body. Optionally pipe the body through a
      summarization prompt to extract answers to a specific question.
      Prefer this over Bash curl for web content.
      """,
      input_schema: %{
        type: "object",
        required: ["url"],
        properties: %{
          url: %{type: "string", description: "HTTPS URL to fetch."},
          prompt: %{
            type: "string",
            description:
              "Optional summarization prompt. If set, the content is summarized with Haiku and only the summary is returned."
          }
        }
      }
    }
  end

  @impl true
  def run(%{"url" => url} = input, _ctx) do
    with :ok <- validate_scheme(url),
         {:ok, body} <- fetch(url),
         {:ok, content} <- maybe_summarize(body, Map.get(input, "prompt")) do
      {:ok, content}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def run(_, _), do: {:error, "WebFetch requires `url` string."}

  # --- helpers ---

  defp validate_scheme("https://" <> _), do: :ok

  defp validate_scheme("http://" <> _) do
    if System.get_env("CRUCIBLE_ALLOW_HTTP") == "1",
      do: :ok,
      else: {:error, "HTTP URLs are blocked. Set CRUCIBLE_ALLOW_HTTP=1 to allow."}
  end

  defp validate_scheme(_), do: {:error, "Only HTTPS URLs are allowed."}

  defp fetch(url) do
    case Req.get(url,
           receive_timeout: @default_timeout_ms,
           redirect: true,
           decode_body: false,
           headers: [{"user-agent", "crucible-webfetch/0.1"}]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, trim_body(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{String.slice(to_string(body), 0, 200)}"}

      {:error, reason} ->
        {:error, "fetch failed: #{inspect(reason)}"}
    end
  end

  defp trim_body(body) when is_binary(body) and byte_size(body) > @max_bytes,
    do: binary_part(body, 0, @max_bytes) <> "\n… (truncated)"

  defp trim_body(body), do: to_string(body)

  defp maybe_summarize(body, nil), do: {:ok, body}

  defp maybe_summarize(body, prompt) when is_binary(prompt) do
    # Best-effort summarization via a short Query invocation on Haiku.
    # Kept synchronous so the calling tool still returns a string.
    api_key = System.get_env("ANTHROPIC_API_KEY")

    if is_binary(api_key) and api_key != "" do
      case Crucible.ElixirSdk.Client.stream(
             api_key: api_key,
             model: "claude-haiku-4-5-20251001",
             messages: [
               %{
                 role: "user",
                 content:
                   "Answer the following question from the content below. Be concise.\n\nQuestion: #{prompt}\n\nContent:\n#{body}"
               }
             ],
             max_tokens: 1024,
             subscriber: self(),
             timeout_ms: @default_timeout_ms
           ) do
        {:ok, _ref} -> collect_summary()
        {:error, reason} -> {:ok, "Summary unavailable (#{inspect(reason)}):\n#{body}"}
      end
    else
      {:ok, body}
    end
  end

  defp collect_summary(acc \\ "") do
    receive do
      {:crucible_sdk, :content_block_delta, %{"delta" => %{"type" => "text_delta", "text" => txt}}} ->
        collect_summary(acc <> txt)

      {:crucible_sdk, :done, _} ->
        {:ok, acc}

      {:crucible_sdk, :error, reason} ->
        {:ok, "Summary unavailable (#{inspect(reason)})"}

      _ ->
        collect_summary(acc)
    after
      @default_timeout_ms -> {:ok, acc}
    end
  end
end
