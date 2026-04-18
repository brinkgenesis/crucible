defmodule CrucibleWeb.BudgetLive.Helpers do
  @moduledoc """
  Pure utility functions for the Budget LiveView.

  Contains formatting, calculation, and URL-building helpers
  extracted from `BudgetLive` to keep the LiveView module focused
  on socket lifecycle and event handling.
  """

  alias CrucibleWeb.Live.ScopeFilters

  @doc """
  Formats a cost value to a 4-decimal-place string.

  Returns `"0.0000"` for nil values.
  """
  def format_cost(nil), do: "0.0000"
  def format_cost(val) when is_number(val), do: Float.round(val * 1.0, 4) |> to_string()

  @doc """
  Truncates an identifier string to 12 characters for display.

  Returns a dash for nil or empty strings.
  """
  def short_id(nil), do: "—"
  def short_id(""), do: "—"
  def short_id(id) when is_binary(id), do: String.slice(id, 0, 12)

  @doc """
  Calculates the bar chart width percentage for a model's cost
  relative to the highest-cost model in the breakdown.
  """
  def model_bar_pct(breakdown, cost) do
    max_cost = breakdown |> Enum.map(& &1.cost) |> Enum.max(fn -> 1 end)
    if max_cost > 0, do: Float.round(cost / max_cost * 100.0, 1), else: 0
  end

  @doc """
  Builds the budget page path with optional client/workspace query params.
  """
  def budget_path(client_filter, workspace_filter) do
    query =
      %{}
      |> ScopeFilters.apply_scope_query(client_filter, workspace_filter)

    "/budget" <> encode_query(query)
  end

  @doc """
  Encodes a map as a URI query string, prefixed with `?`.

  Returns an empty string for empty maps.
  """
  def encode_query(query) when map_size(query) == 0, do: ""
  def encode_query(query), do: "?" <> URI.encode_query(query)

  @doc """
  Calculates the spend percentage against the daily limit.

  Returns `0.0` if the daily limit is zero.
  """
  def spend_percentage(daily_spent, daily_limit) do
    if daily_limit > 0 do
      Float.round(daily_spent / daily_limit * 100.0, 1)
    else
      0.0
    end
  end

  @doc """
  Builds the model cost breakdown from a list of cost events.

  Groups events by `model_id`, sums costs, and sorts descending by total cost.
  """
  def model_breakdown(events) do
    events
    |> Enum.filter(&Map.has_key?(&1, :model_id))
    |> Enum.group_by(& &1.model_id)
    |> Enum.map(fn {model, evts} ->
      total = evts |> Enum.map(&(Map.get(&1, :cost_usd, 0) || 0)) |> Enum.sum()
      %{model: model, cost: total * 1.0, count: length(evts)}
    end)
    |> Enum.sort_by(& &1.cost, :desc)
  end

  @doc """
  Generates CSV content from a list of cost events.

  Returns `{csv_binary, filename, content_type}`.
  """
  def events_to_csv(events) do
    csv =
      [
        "timestamp,tool,model,session,cost_usd\n"
        | Enum.map(events, fn e ->
            ts = Map.get(e, :timestamp, "")
            tool = Map.get(e, :tool, "")
            model = Map.get(e, :model_id, "")
            session = Map.get(e, :session, "")
            cost = Map.get(e, :cost_usd, 0)
            "#{ts},#{tool},#{model},#{session},#{cost}\n"
          end)
      ]
      |> IO.iodata_to_binary()

    {csv, "budget-events-#{Date.to_iso8601(Date.utc_today())}.csv", "text/csv"}
  end

  @doc """
  Generates JSON content from a list of cost events.

  Returns `{json_binary, filename, content_type}`.
  """
  def events_to_json(events) do
    json =
      Enum.map(events, fn e ->
        %{
          timestamp: Map.get(e, :timestamp),
          tool: Map.get(e, :tool),
          model: Map.get(e, :model_id),
          session: Map.get(e, :session),
          cost_usd: Map.get(e, :cost_usd, 0)
        }
      end)
      |> Jason.encode!(pretty: true)

    {json, "budget-events-#{Date.to_iso8601(Date.utc_today())}.json", "application/json"}
  end
end
