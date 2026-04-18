defmodule CrucibleWeb.Api.BudgetController do
  use CrucibleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Crucible.BudgetTracker
  alias Crucible.CostEventReader
  alias CrucibleWeb.HealthSnapshot
  alias CrucibleWeb.Schemas.Common.{BudgetStatus, BudgetBreakdownItem, ErrorResponse}

  tags(["Budget"])
  security([%{"cookieAuth" => []}])

  operation(:status,
    summary: "Get budget status",
    description: "Returns current daily budget utilization and limits.",
    responses: [ok: {"Budget status", "application/json", BudgetStatus}]
  )

  def status(conn, _params) do
    json(conn, HealthSnapshot.budget_status())
  end

  operation(:history,
    summary: "Get budget history",
    description: "Returns daily spending history for the specified number of days.",
    parameters: [
      days: [
        in: :query,
        type: :integer,
        required: false,
        description: "Number of days (default 7)"
      ]
    ],
    responses: [
      ok:
        {"Budget history", "application/json",
         %OpenApiSpex.Schema{type: :array, items: BudgetStatus}},
      bad_request: {"Invalid days parameter", "application/json", ErrorResponse}
    ]
  )

  def history(conn, params) do
    case parse_pos_integer(params, "days", 7) do
      {:ok, days} ->
        history = safe_call(fn -> BudgetTracker.daily_history(days) end, [])
        json(conn, history)

      {:error, msg} ->
        conn |> put_status(400) |> json(%{error: msg})
    end
  end

  operation(:breakdown,
    summary: "Get cost breakdown by model",
    description: "Returns per-model cost breakdown for the specified time window.",
    parameters: [
      days: [
        in: :query,
        type: :integer,
        required: false,
        description: "Number of days (default 1)"
      ],
      client_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Filter by client ID"
      ],
      workspace: [
        in: :query,
        type: :string,
        required: false,
        description: "Filter by workspace path"
      ]
    ],
    responses: [
      ok:
        {"Cost breakdown", "application/json",
         %OpenApiSpex.Schema{type: :array, items: BudgetBreakdownItem}}
    ]
  )

  def breakdown(conn, params) do
    client_id = blank_to_nil(Map.get(params, "client_id") || Map.get(params, "clientId"))
    workspace = blank_to_nil(Map.get(params, "workspace"))

    days =
      case parse_pos_integer(params, "days", 1) do
        {:ok, d} -> d
        {:error, _} -> 1
      end

    events =
      if client_id || workspace do
        safe_call(
          fn -> CostEventReader.all_sessions(limit: 1500, client_id: client_id, workspace: workspace) end,
          []
        )
        |> Enum.map(fn session ->
          %{
            timestamp: parse_iso8601(Map.get(session, :last_seen)),
            model_id: Map.get(session, :model_id),
            cost_usd: Map.get(session, :total_cost_usd, 0.0)
          }
        end)
      else
        safe_call(fn -> BudgetTracker.recent_events(500) end, [])
      end

    # Filter to requested time window
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    filtered =
      events
      |> Enum.filter(fn evt ->
        case Map.get(evt, :timestamp) do
          %DateTime{} = ts -> DateTime.compare(ts, cutoff) == :gt
          _ -> true
        end
      end)

    breakdown =
      filtered
      |> Enum.filter(&Map.has_key?(&1, :model_id))
      |> Enum.group_by(& &1.model_id)
      |> Enum.map(fn {model, evts} ->
        cost = evts |> Enum.map(&(Map.get(&1, :cost_usd, 0) || 0)) |> Enum.sum()
        %{model: model, cost: cost, count: length(evts)}
      end)
      |> Enum.sort_by(& &1.cost, :desc)

    json(conn, breakdown)
  end

  operation(:sessions,
    summary: "Get active sessions",
    description: "Returns all active cost-tracking sessions.",
    parameters: [
      client_id: [in: :query, type: :string, required: false, description: "Filter by client ID"],
      workspace: [in: :query, type: :string, required: false, description: "Filter by workspace path"]
    ],
    responses: [
      ok:
        {"Sessions list", "application/json",
         %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}}}
    ]
  )

  def sessions(conn, params) do
    client_id = blank_to_nil(Map.get(params, "client_id") || Map.get(params, "clientId"))
    workspace = blank_to_nil(Map.get(params, "workspace"))

    sessions =
      safe_call(fn -> CostEventReader.all_sessions(client_id: client_id, workspace: workspace) end, [])

    json(conn, sessions)
  end

  operation(:alerts,
    summary: "Get budget alerts",
    description: "Returns active budget alerts (warnings and critical).",
    responses: [ok: {"Budget alerts", "application/json", %OpenApiSpex.Schema{type: :object}}]
  )

  def alerts(conn, _params) do
    status =
      safe_call(fn -> BudgetTracker.status() end, %{
        daily_spent: 0.0,
        daily_limit: 100.0,
        is_over_budget: false
      })

    alerts = []

    warning_pct =
      Application.get_env(:crucible, :alerting, [])
      |> Keyword.get(:budget_warning_pct, 80)

    utilization =
      if status.daily_limit > 0,
        do: status.daily_spent / status.daily_limit * 100,
        else: 0

    alerts =
      if status.is_over_budget do
        [
          %{
            level: "critical",
            message: "Budget exceeded",
            spent: status.daily_spent,
            limit: status.daily_limit
          }
          | alerts
        ]
      else
        alerts
      end

    alerts =
      if utilization >= warning_pct and not status.is_over_budget do
        [
          %{
            level: "warning",
            message: "Budget at #{Float.round(utilization, 1)}%",
            spent: status.daily_spent,
            limit: status.daily_limit
          }
          | alerts
        ]
      else
        alerts
      end

    json(conn, %{alerts: alerts, utilization: Float.round(utilization, 1)})
  end

  defp parse_pos_integer(params, key, default) do
    case Map.get(params, key) do
      nil ->
        {:ok, default}

      val when is_integer(val) and val > 0 ->
        {:ok, val}

      val when is_binary(val) ->
        case Integer.parse(val) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> {:error, "invalid #{key}: must be a positive integer"}
        end

      _ ->
        {:error, "invalid #{key}: must be a positive integer"}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp parse_iso8601(nil), do: nil

  defp parse_iso8601(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_iso8601(_), do: nil
end
