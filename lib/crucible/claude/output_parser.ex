defmodule Crucible.Claude.OutputParser do
  @moduledoc """
  Parses Claude CLI stdout: ANSI stripping, URL detection, cost/token extraction.
  """

  @ansi_regex ~r/\x1b\[[0-9;]*[a-zA-Z]/
  @url_regex ~r|https?://[^\s\)>\]]+|
  @cost_regex ~r/\$(\d+\.\d{2})/
  @tokens_total_regex ~r/(\d+\.?\d*k?)\s*tokens?\s*total/i
  @session_url_regex ~r|https://claude\.ai/[^\s\)]+|

  @doc "Strips ANSI escape codes from text."
  @spec strip_ansi(String.t()) :: String.t()
  def strip_ansi(text) do
    String.replace(text, @ansi_regex, "")
  end

  @doc "Extracts all URLs from output."
  @spec extract_urls(String.t()) :: [String.t()]
  def extract_urls(text) do
    clean = strip_ansi(text)
    Regex.scan(@url_regex, clean) |> Enum.map(&hd/1)
  end

  @doc "Extracts the Claude session URL if present."
  @spec extract_session_url(String.t()) :: String.t() | nil
  def extract_session_url(text) do
    clean = strip_ansi(text)

    case Regex.run(@session_url_regex, clean) do
      [url | _] -> url
      nil -> nil
    end
  end

  @session_id_regex ~r|https://claude\.ai/chat/([a-f0-9-]+)|
  @doc "Extracts the Claude session ID from output (parsed from session URL)."
  @spec extract_session_id(String.t()) :: String.t() | nil
  def extract_session_id(text) do
    clean = strip_ansi(text)

    case Regex.run(@session_id_regex, clean) do
      [_, id] -> id
      nil -> nil
    end
  end

  @doc "Extracts cost in USD from output."
  @spec extract_cost(String.t()) :: float() | nil
  def extract_cost(text) do
    clean = strip_ansi(text)

    case Regex.run(@cost_regex, clean) do
      [_, amount] ->
        case Float.parse(amount) do
          {f, _} -> f
          :error -> nil
        end

      nil ->
        nil
    end
  end

  @doc "Extracts token counts from output."
  @spec extract_tokens(String.t()) :: %{total: integer() | nil}
  def extract_tokens(text) do
    clean = strip_ansi(text)

    total =
      case Regex.run(@tokens_total_regex, clean) do
        [_, num_str] -> parse_token_count(num_str)
        nil -> nil
      end

    %{total: total}
  end

  @doc "Detects error patterns in output."
  @spec detect_error(String.t()) :: String.t() | nil
  def detect_error(text) do
    clean = strip_ansi(text)

    cond do
      clean =~ ~r/Error:|FATAL|Traceback|panic:/i ->
        # Extract the error line
        clean
        |> String.split("\n")
        |> Enum.find(&(&1 =~ ~r/Error:|FATAL|Traceback|panic:/i))
        |> String.trim()

      true ->
        nil
    end
  end

  @doc "Parses a sentinel file for phase completion."
  @spec parse_sentinel(String.t(), String.t() | nil) :: {:ok, map()} | :not_done
  def parse_sentinel(path, base_commit \\ nil) do
    case File.read(path) do
      {:ok, content} ->
        content = String.trim(content)

        cond do
          content in ["done", "done (skip-if-planned)"] ->
            {:ok, %{status: "done", commit_hash: nil, no_changes: false}}

          true ->
            case Jason.decode(content) do
              {:ok, %{"commitHash" => hash} = data} ->
                no_changes = Map.get(data, "noChanges", false)

                if no_changes or is_nil(base_commit) or hash != base_commit do
                  {:ok, %{status: "done", commit_hash: hash, no_changes: no_changes}}
                else
                  # Stale sentinel
                  :not_done
                end

              _ ->
                :not_done
            end
        end

      {:error, _} ->
        :not_done
    end
  end

  # --- Private ---

  defp parse_token_count(str) do
    if String.contains?(str, ".") do
      case Float.parse(str) do
        {f, rest} ->
          if String.trim(rest) =~ ~r/^k/i, do: round(f * 1000), else: round(f)

        :error ->
          nil
      end
    else
      case Integer.parse(str) do
        {n, rest} ->
          if String.trim(rest) =~ ~r/^k/i, do: n * 1000, else: n

        :error ->
          nil
      end
    end
  end
end
