defmodule Crucible.DotenvLoader do
  @moduledoc """
  Minimal `.env` loader used by `config/runtime.exs` to make local scripts
  (`mix run …`) and `iex -S mix` find `ANTHROPIC_API_KEY` et al. without the
  caller having to remember `set -a && source .env`.

  Rules:
  * Blank lines and `#` comments are ignored.
  * `KEY=value` — leading/trailing whitespace trimmed, surrounding single or
    double quotes stripped.
  * Existing `System.get_env(key)` values are **never** overwritten — CI,
    launchd, and containers already set env directly and should win.
  * Missing or unreadable file is a no-op, not an error.
  """

  @spec load(Path.t()) :: :ok
  def load(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split(~r/\r?\n/)
        |> Enum.each(&maybe_put/1)

      _ ->
        :ok
    end

    :ok
  end

  defp maybe_put(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" -> :ok
      String.starts_with?(trimmed, "#") -> :ok
      true -> parse_and_put(trimmed)
    end
  end

  defp parse_and_put(line) do
    case String.split(line, "=", parts: 2) do
      [key, raw] ->
        key = String.trim(key)
        value = raw |> String.trim() |> strip_quotes()

        if key != "" and System.get_env(key) == nil do
          System.put_env(key, value)
        end

      _ ->
        :ok
    end
  end

  defp strip_quotes(<<?", _::binary>> = v), do: v |> String.trim_leading("\"") |> String.trim_trailing("\"")
  defp strip_quotes(<<?', _::binary>> = v), do: v |> String.trim_leading("'") |> String.trim_trailing("'")
  defp strip_quotes(v), do: v
end
