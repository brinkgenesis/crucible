defmodule CrucibleWeb.TracesLive.Helpers do
  @moduledoc """
  Trace-specific formatting helpers for the TracesLive views.

  Provides functions for formatting trace comparison deltas (duration, tokens, cost),
  phase name labels, timeline ticks, trace source labels, regression signals, and
  CSS utility classes used in the trace analytics dashboard.

  For generic formatting (timestamps, durations, token counts), see
  `CrucibleWeb.FormatHelpers`.
  """

  import CrucibleWeb.FormatHelpers, only: [format_duration_ms: 1, format_tokens: 1]

  # ---------------------------------------------------------------------------
  # Signed delta formatters (for trace comparison view)
  # ---------------------------------------------------------------------------

  @doc """
  Format a duration delta in milliseconds with a sign prefix.

  Positive values get a `+` prefix, negative values keep their `-`.
  Delegates to `FormatHelpers.format_duration_ms/1` for the magnitude.

  ## Examples

      iex> CrucibleWeb.TracesLive.Helpers.format_signed_duration(5_400)
      "+5s"

      iex> CrucibleWeb.TracesLive.Helpers.format_signed_duration(-120_000)
      "-2m 0s"

      iex> CrucibleWeb.TracesLive.Helpers.format_signed_duration(nil)
      "0s"
  """
  @spec format_signed_duration(number() | nil) :: String.t()
  def format_signed_duration(delta_ms) when is_number(delta_ms) do
    prefix = if delta_ms > 0, do: "+", else: ""
    prefix <> format_duration_ms(abs(round(delta_ms)))
  end

  def format_signed_duration(_), do: "0s"

  @doc """
  Format a token count delta with a sign prefix and human-readable magnitude.

  Uses `FormatHelpers.format_tokens/1` for the magnitude (e.g. `1.2K`, `3.4M`).

  ## Examples

      iex> CrucibleWeb.TracesLive.Helpers.format_signed_tokens(2500)
      "+2.5K"

      iex> CrucibleWeb.TracesLive.Helpers.format_signed_tokens(-100)
      "-100"
  """
  @spec format_signed_tokens(number() | nil) :: String.t()
  def format_signed_tokens(delta) when is_number(delta) do
    prefix = if delta > 0, do: "+", else: ""
    prefix <> format_tokens(abs(round(delta)))
  end

  def format_signed_tokens(_), do: "0"

  @doc """
  Format a cost delta in USD with a sign prefix and 4 decimal places.

  ## Examples

      iex> CrucibleWeb.TracesLive.Helpers.format_signed_cost(0.0523)
      "+$0.0523"

      iex> CrucibleWeb.TracesLive.Helpers.format_signed_cost(-1.25)
      "-$1.2500"
  """
  @spec format_signed_cost(number() | nil) :: String.t()
  def format_signed_cost(delta) when is_number(delta) do
    prefix = if delta > 0, do: "+", else: ""
    prefix <> "$" <> :erlang.float_to_binary(abs(delta / 1), decimals: 4)
  end

  def format_signed_cost(_), do: "$0.0000"

  # ---------------------------------------------------------------------------
  # Timeline formatting
  # ---------------------------------------------------------------------------

  @doc """
  Format a millisecond value for timeline tick labels.

  Returns `"0s"` for zero or negative values, otherwise delegates to
  `FormatHelpers.format_duration_ms/1`.

  ## Examples

      iex> CrucibleWeb.TracesLive.Helpers.format_timeline_ms(0)
      "0s"

      iex> CrucibleWeb.TracesLive.Helpers.format_timeline_ms(65_000)
      "1m 5s"
  """
  @spec format_timeline_ms(number()) :: String.t()
  def format_timeline_ms(ms) when is_number(ms) and ms <= 0, do: "0s"
  def format_timeline_ms(ms), do: format_duration_ms(ms)

  # ---------------------------------------------------------------------------
  # Phase name formatting
  # ---------------------------------------------------------------------------

  @doc """
  Format a workflow phase name slug into a human-readable title.

  Replaces hyphens and underscores with spaces and capitalizes each word.

  ## Examples

      iex> CrucibleWeb.TracesLive.Helpers.format_phase_name("coding-sprint")
      "Coding Sprint"

      iex> CrucibleWeb.TracesLive.Helpers.format_phase_name("plan_review")
      "Plan Review"

      iex> CrucibleWeb.TracesLive.Helpers.format_phase_name(nil)
      "Trace"
  """
  @spec format_phase_name(String.t() | nil) :: String.t()
  def format_phase_name(name) when is_binary(name) do
    name
    |> String.replace(~r/[-_]/, " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def format_phase_name(_), do: "Trace"

  # ---------------------------------------------------------------------------
  # Trace source labels
  # ---------------------------------------------------------------------------

  @doc """
  Return a human-readable label for a trace data source atom.

  ## Examples

      iex> CrucibleWeb.TracesLive.Helpers.source_label(:postgres)
      "Postgres"

      iex> CrucibleWeb.TracesLive.Helpers.source_label(:unknown)
      "Unknown"
  """
  @spec source_label(atom()) :: String.t()
  def source_label(:postgres), do: "Postgres"
  def source_label(:filesystem), do: "Filesystem"
  def source_label(:jsonl), do: "JSONL"
  def source_label(:empty), do: "Empty"
  def source_label(_), do: "Unknown"

  # ---------------------------------------------------------------------------
  # CSS utility classes
  # ---------------------------------------------------------------------------

  @doc """
  Return a Tailwind CSS class for a numeric delta value.

  Positive deltas (regressions) are red, negative (improvements) are green,
  and zero/nil is neutral white.

  ## Examples

      iex> CrucibleWeb.TracesLive.Helpers.hud_delta_class(10)
      "text-[#ff725e]"

      iex> CrucibleWeb.TracesLive.Helpers.hud_delta_class(-5)
      "text-[#00FF41]"

      iex> CrucibleWeb.TracesLive.Helpers.hud_delta_class(0)
      "text-white"
  """
  @spec hud_delta_class(number() | nil) :: String.t()
  def hud_delta_class(delta) when is_number(delta) and delta > 0, do: "text-[#ff725e]"
  def hud_delta_class(delta) when is_number(delta) and delta < 0, do: "text-[#00FF41]"
  def hud_delta_class(_), do: "text-white"

  @doc """
  Return a Tailwind CSS class for a trace source confidence level.

  High confidence is green, medium is amber, low/unknown is red.

  ## Examples

      iex> CrucibleWeb.TracesLive.Helpers.source_confidence_class("high")
      "bg-[#00FF41]/10 text-[#00FF41] border border-[#00FF41]/30"
  """
  @spec source_confidence_class(String.t()) :: String.t()
  def source_confidence_class("high"),
    do: "bg-[#00FF41]/10 text-[#00FF41] border border-[#00FF41]/30"

  def source_confidence_class("medium"),
    do: "bg-[#ffa44c]/10 text-[#ffa44c] border border-[#ffa44c]/30"

  def source_confidence_class(_),
    do: "bg-[#ff7351]/10 text-[#ff7351] border border-[#ff7351]/30"

  @doc """
  Return a Tailwind CSS class for a trace run status badge.

  ## Examples

      iex> CrucibleWeb.TracesLive.Helpers.status_badge_class("done")
      "bg-[#00FF41]/10 text-[#00FF41] border border-[#00FF41]/30"

      iex> CrucibleWeb.TracesLive.Helpers.status_badge_class("running")
      "bg-[#00eefc]/10 text-[#00eefc] border border-[#00eefc]/30"
  """
  @spec status_badge_class(String.t() | nil) :: String.t()
  def status_badge_class(status) when status in ["done", "completed"],
    do: "bg-[#00FF41]/10 text-[#00FF41] border border-[#00FF41]/30"

  def status_badge_class(status) when status in ["running", "in_progress"],
    do: "bg-[#00eefc]/10 text-[#00eefc] border border-[#00eefc]/30"

  def status_badge_class(status) when status in ["failed", "error"],
    do: "bg-[#ff725e]/10 text-[#ff725e] border border-[#ff725e]/30"

  def status_badge_class(_),
    do: "bg-[#ffa44c]/10 text-[#ffa44c] border border-[#ffa44c]/30"

  # ---------------------------------------------------------------------------
  # Regression signal helpers
  # ---------------------------------------------------------------------------

  @doc """
  Split a semicolon-delimited regression signal summary into a list of signals.

  ## Examples

      iex> CrucibleWeb.TracesLive.Helpers.split_signals("Cost up 25%; Duration up 15%")
      ["Cost up 25%", "Duration up 15%"]

      iex> CrucibleWeb.TracesLive.Helpers.split_signals(nil)
      []
  """
  @spec split_signals(String.t() | nil) :: [String.t()]
  def split_signals(summary) when is_binary(summary) do
    summary
    |> String.split(";", trim: true)
    |> Enum.map(&String.trim/1)
  end

  def split_signals(_), do: []

  @doc """
  Format a float as a percentage string.

  ## Examples

      iex> CrucibleWeb.TracesLive.Helpers.format_pct(0.857)
      "86%"

      iex> CrucibleWeb.TracesLive.Helpers.format_pct(nil)
      "0%"
  """
  @spec format_pct(number() | nil) :: String.t()
  def format_pct(value) when is_number(value), do: "#{Float.round(value * 100, 0)}%"
  def format_pct(_), do: "0%"
end
