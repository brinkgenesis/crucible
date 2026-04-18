defmodule CrucibleWeb.CostLive.Helpers do
  @moduledoc """
  Pure helper functions for CostLive: cost formatting, token aggregation,
  percentage display, model classification, and chart styling utilities.

  All functions are side-effect-free -- no socket or assign manipulation.
  """

  @model_colors %{
    "opus" => "#ff725e",
    "sonnet" => "#00eefc",
    "haiku" => "#00FF41",
    "minimax" => "#ffa44c",
    "gemini" => "#fd9000"
  }

  # ---------------------------------------------------------------------------
  # Cost Formatting
  # ---------------------------------------------------------------------------

  @doc """
  Format a USD cost value to a decimal string for display.

  ## Examples

      iex> format_cost(1.5)
      "1.5"

      iex> format_cost(nil)
      "0.00"
  """
  @spec format_cost(number() | nil) :: String.t()
  def format_cost(val) when is_number(val), do: Float.round(val * 1.0, 2) |> to_string()
  def format_cost(_), do: "0.00"

  @doc """
  Format a USD cost with a dollar sign prefix, suitable for display in tables.

  ## Examples

      iex> format_cost_label(3.14)
      "$3.14"

      iex> format_cost_label(nil)
      "$0.00"
  """
  @spec format_cost_label(number() | nil) :: String.t()
  def format_cost_label(val), do: "$#{format_cost(val)}"

  # ---------------------------------------------------------------------------
  # Date Formatting
  # ---------------------------------------------------------------------------

  @doc """
  Format an ISO 8601 timestamp to a date-only string (YYYY-MM-DD).

  ## Examples

      iex> format_date("2026-03-26T12:34:56Z")
      "2026-03-26"

      iex> format_date(nil)
      "\u2014"
  """
  @spec format_date(String.t() | nil) :: String.t()
  def format_date(nil), do: "\u2014"
  def format_date(ts) when is_binary(ts), do: String.slice(ts, 0, 10)

  @doc """
  Format a date string to a compact M/D display for chart labels.

  ## Examples

      iex> short_date("2026-03-26")
      "3/26"

      iex> short_date("invalid")
      "invalid"
  """
  @spec short_date(String.t()) :: String.t()
  def short_date(date) when is_binary(date) do
    case String.split(date, "-") do
      [_, m, d] -> "#{String.to_integer(m)}/#{String.to_integer(d)}"
      _ -> date
    end
  end

  # ---------------------------------------------------------------------------
  # Source Labels
  # ---------------------------------------------------------------------------

  @doc """
  Convert a cost data source atom to a human-readable label.

  ## Examples

      iex> source_label(:postgres)
      "Postgres"

      iex> source_label(:unknown)
      "Unknown"
  """
  @spec source_label(atom()) :: String.t()
  def source_label(:postgres), do: "Postgres"
  def source_label(:jsonl), do: "JSONL"
  def source_label(:empty), do: "Empty"
  def source_label(_), do: "Unknown"

  # ---------------------------------------------------------------------------
  # Token Aggregation
  # ---------------------------------------------------------------------------

  @doc """
  Calculate the total tokens across all session rows.
  """
  @spec summary_total_tokens([map()]) :: non_neg_integer()
  def summary_total_tokens(rows) do
    Enum.reduce(rows, 0, &(&2 + session_total_tokens(&1)))
  end

  @doc """
  Calculate the total input tokens across all session rows.
  """
  @spec summary_input_tokens([map()]) :: non_neg_integer()
  def summary_input_tokens(rows) do
    Enum.reduce(rows, 0, &(&2 + (Map.get(&1, :input_tokens) || 0)))
  end

  @doc """
  Calculate the total output tokens across all session rows.
  """
  @spec summary_output_tokens([map()]) :: non_neg_integer()
  def summary_output_tokens(rows) do
    Enum.reduce(rows, 0, &(&2 + (Map.get(&1, :output_tokens) || 0)))
  end

  @doc """
  Extract the total token count from a session row, preferring `total_tokens`
  and falling back to summing input + output + cache_creation tokens.
  """
  @spec session_total_tokens(map()) :: non_neg_integer()
  def session_total_tokens(%{total_tokens: total}) when is_number(total), do: total

  def session_total_tokens(session) do
    Map.get(session, :total_input_tokens, Map.get(session, :input_tokens, 0)) +
      Map.get(session, :total_output_tokens, Map.get(session, :output_tokens, 0)) +
      Map.get(session, :total_cache_creation_tokens, Map.get(session, :cache_creation_tokens, 0))
  end

  # ---------------------------------------------------------------------------
  # Percentage & Efficiency Formatting
  # ---------------------------------------------------------------------------

  @doc """
  Calculate the cache hit rate as a formatted percentage string from session rows.

  ## Examples

      iex> cache_hit_rate([%{input_tokens: 80, cache_read_tokens: 20}])
      "20.0%"

      iex> cache_hit_rate([])
      "\u2014"
  """
  @spec cache_hit_rate([map()]) :: String.t()
  def cache_hit_rate(rows) do
    total_input = summary_input_tokens(rows)
    total_cache_read = Enum.reduce(rows, 0, &(&2 + (Map.get(&1, :cache_read_tokens) || 0)))

    if total_input + total_cache_read > 0 do
      "#{Float.round(total_cache_read / (total_input + total_cache_read) * 100, 1)}%"
    else
      "\u2014"
    end
  end

  @doc """
  Format the context compression savings ratio as a percentage string.

  ## Examples

      iex> context_saved_pct(%{"totalSavedRatio" => 0.42})
      "42.0%"

      iex> context_saved_pct(nil)
      "\u2014"
  """
  @spec context_saved_pct(map() | nil) :: String.t()
  def context_saved_pct(nil), do: "\u2014"

  def context_saved_pct(%{"totalSavedRatio" => r}) when is_number(r),
    do: "#{Float.round(r * 100, 1)}%"

  def context_saved_pct(_), do: "\u2014"

  @doc """
  Generate a subtitle describing context compression savings.

  ## Examples

      iex> context_saved_subtitle(%{"totalSavedTokens" => 150_000})
      "150K tokens saved"

      iex> context_saved_subtitle(nil)
      "no data"
  """
  @spec context_saved_subtitle(map() | nil) :: String.t()
  def context_saved_subtitle(nil), do: "no data"

  def context_saved_subtitle(%{"totalSavedTokens" => t}) when is_number(t) do
    "#{format_tokens_compact(t)} tokens saved"
  end

  def context_saved_subtitle(_), do: "no data"

  # ---------------------------------------------------------------------------
  # Model Classification & Colors
  # ---------------------------------------------------------------------------

  @doc """
  Classify a model identifier string into a model family.

  ## Examples

      iex> model_family("claude-3-opus-20240229")
      "opus"

      iex> model_family("gemini-2.5-flash")
      "gemini"
  """
  @spec model_family(String.t()) :: String.t()
  def model_family(model) do
    m = String.downcase(model)

    cond do
      String.contains?(m, "opus") -> "opus"
      String.contains?(m, "sonnet") -> "sonnet"
      String.contains?(m, "haiku") -> "haiku"
      String.contains?(m, "minimax") or String.contains?(m, "m2") -> "minimax"
      String.contains?(m, "gemini") or String.contains?(m, "flash") -> "gemini"
      true -> "other"
    end
  end

  @doc """
  Return the hex color associated with a model, classified by family.
  """
  @spec model_color(String.t()) :: String.t()
  def model_color(model), do: Map.get(@model_colors, model_family(model), "#94a3b8")

  @doc """
  Return the chart area color for a given view mode.
  """
  @spec chart_color(String.t()) :: String.t()
  def chart_color("dollars"), do: "#ffa44c"
  def chart_color(_), do: "#00eefc"

  @doc "Chart grid line color."
  @spec chart_grid_color() :: String.t()
  def chart_grid_color, do: "rgba(255, 164, 76, 0.08)"

  @doc "Chart axis label color."
  @spec chart_label_color() :: String.t()
  def chart_label_color, do: "rgba(255, 164, 76, 0.5)"

  # ---------------------------------------------------------------------------
  # Budget Status
  # ---------------------------------------------------------------------------

  @doc """
  Format a budget status map into a human-readable summary string.

  ## Examples

      iex> format_budget_status(%{daily_spent: 42.5, daily_limit: 100.0})
      "$42.5 / $100.0"

      iex> format_budget_status(nil)
      "No budget data"
  """
  @spec format_budget_status(map() | nil) :: String.t()
  def format_budget_status(nil), do: "No budget data"

  def format_budget_status(%{daily_spent: spent, daily_limit: limit})
      when is_number(spent) and is_number(limit) do
    "$#{format_cost(spent)} / $#{format_cost(limit)}"
  end

  def format_budget_status(_), do: "No budget data"

  @doc """
  Return the budget utilization as a percentage (0-100).

  ## Examples

      iex> budget_utilization_pct(%{daily_spent: 75.0, daily_limit: 100.0})
      75.0

      iex> budget_utilization_pct(%{daily_spent: 0, daily_limit: 0})
      0.0
  """
  @spec budget_utilization_pct(map()) :: float()
  def budget_utilization_pct(%{daily_spent: spent, daily_limit: limit})
      when is_number(spent) and is_number(limit) and limit > 0 do
    Float.round(spent / limit * 100, 1)
  end

  def budget_utilization_pct(_), do: 0.0

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Compact token formatting for subtitle text (e.g., "150K tokens saved").
  # Delegates to FormatHelpers when available via the LiveView import,
  # but provides a standalone fallback here for pure-helper usage.
  defp format_tokens_compact(n) when is_number(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  defp format_tokens_compact(n) when is_number(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}K"

  defp format_tokens_compact(n) when is_number(n), do: "#{n}"
  defp format_tokens_compact(_), do: "0"
end
