defmodule CrucibleWeb.FormatHelpers do
  @moduledoc "Shared formatting helpers for LiveView templates."

  @doc "Format an ISO8601 timestamp or DateTime to HH:MM:SS."
  def format_time(nil), do: ""
  def format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")

  def format_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> String.slice(ts, 11, 8)
    end
  end

  def format_time(_), do: "\u2014"

  @doc "Format milliseconds to human-readable duration."
  def format_duration_ms(ms) when is_number(ms) and ms > 0 do
    s = div(trunc(ms), 1000)

    cond do
      s < 1 -> "<1s"
      s < 60 -> "#{s}s"
      s < 3600 -> "#{div(s, 60)}m #{rem(s, 60)}s"
      true -> "#{div(s, 3600)}h #{rem(div(s, 60), 60)}m"
    end
  end

  def format_duration_ms(_), do: "\u2014"

  @doc "Format large token counts to human-readable strings (e.g. 1.2M, 3.4K)."
  def format_tokens(n) when is_number(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  def format_tokens(n) when is_number(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}K"

  def format_tokens(n) when is_number(n), do: "#{n}"
  def format_tokens(_), do: "0"
end
