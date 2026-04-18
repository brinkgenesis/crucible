defmodule CrucibleWeb.Api.AlertWebhookController do
  @moduledoc """
  Receives Alertmanager webhook payloads and broadcasts them to the internal
  alert feed so the AlertManager GenServer can evaluate rules and dispatch.

  Alertmanager sends POST with JSON body containing `alerts` array.
  Each alert has `status`, `labels`, `annotations`, `startsAt`, `endsAt`.
  """
  use CrucibleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Crucible.Events
  require Logger

  tags(["Alerts"])
  security([%{"cookieAuth" => []}])

  operation(:receive,
    summary: "Receive Alertmanager webhook",
    description:
      "Accepts incoming Alertmanager webhook payloads and broadcasts them to the internal alert feed. Requires a Bearer token when ALERTMANAGER_WEBHOOK_TOKEN is configured.",
    responses: [
      ok: {"Processed alerts", "application/json", %OpenApiSpex.Schema{type: :object}},
      bad_request:
        {"Missing alerts array", "application/json", %OpenApiSpex.Schema{type: :object}},
      unauthorized: {"Invalid token", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  # Verify webhook requests come from a trusted source.
  # Set ALERTMANAGER_WEBHOOK_TOKEN to require Bearer auth on this endpoint.
  # When unset (dev), all requests are accepted.
  defp verify_webhook_token(conn) do
    case Application.get_env(:crucible, :alerting)[:webhook_token] do
      nil ->
        :ok

      expected_token ->
        case Plug.Conn.get_req_header(conn, "authorization") do
          ["Bearer " <> token] ->
            if Plug.Crypto.secure_compare(token, expected_token), do: :ok, else: :unauthorized

          _ ->
            :unauthorized
        end
    end
  end

  @doc """
  Handles incoming Alertmanager webhook notifications.

  Expected payload:
    {
      "status": "firing",
      "alerts": [
        {
          "status": "firing",
          "labels": {"alertname": "DailyCostCritical", "severity": "critical"},
          "annotations": {"summary": "...", "description": "..."},
          "startsAt": "2026-03-17T12:00:00Z",
          "endsAt": "0001-01-01T00:00:00Z"
        }
      ]
    }
  """
  def receive(conn, %{"alerts" => alerts}) when is_list(alerts) do
    case verify_webhook_token(conn) do
      :unauthorized ->
        conn |> put_status(401) |> json(%{error: "unauthorized"}) |> halt()

      :ok ->
        do_receive(conn, alerts)
    end
  end

  def receive(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "bad_request", message: "Expected 'alerts' array in payload"})
  end

  defp do_receive(conn, alerts) do
    # Validate and filter alerts — reject malformed entries
    {valid, invalid} =
      Enum.split_with(alerts, fn alert ->
        is_map(alert) and is_map(Map.get(alert, "labels")) and
          is_binary(get_in(alert, ["labels", "alertname"])) and
          is_binary(Map.get(alert, "status"))
      end)

    if invalid != [] do
      Logger.warning("AlertWebhook: rejected #{length(invalid)} malformed alert(s)")
    end

    processed =
      Enum.map(valid, fn alert ->
        event_type = map_alert_to_event(alert)
        data = extract_data(alert)

        Events.broadcast_alert_event(event_type, data)

        Logger.info(
          "AlertWebhook: received #{alert["status"]} alert #{get_in(alert, ["labels", "alertname"])}"
        )

        %{alertname: get_in(alert, ["labels", "alertname"]), status: alert["status"]}
      end)

    conn
    |> put_status(200)
    |> json(%{status: "ok", processed: length(processed), alerts: processed})
  end

  # Map Alertmanager alertname to internal event types
  defp map_alert_to_event(%{"labels" => %{"alertname" => name}}) do
    case name do
      "DailyCostWarning" -> :budget_warning
      "DailyCostCritical" -> :budget_exceeded
      "HighTokenUsage" -> :high_token_usage
      "RunFailureRate" -> :run_failed
      "ServiceDown" -> :circuit_breaker_open
      "BackupStale" -> :backup_stale
      "HighErrorRate" -> :high_error_rate
      "HighLatency" -> :high_latency
      _ -> :prometheus_alert
    end
  end

  defp map_alert_to_event(_), do: :prometheus_alert

  defp extract_data(alert) do
    %{
      alertname: get_in(alert, ["labels", "alertname"]) || "unknown",
      severity: get_in(alert, ["labels", "severity"]) || "info",
      status: alert["status"] || "firing",
      summary: get_in(alert, ["annotations", "summary"]) || "",
      description: get_in(alert, ["annotations", "description"]) || "",
      starts_at: alert["startsAt"] || "",
      ends_at: alert["endsAt"] || "",
      source: :alertmanager
    }
  end
end
