defmodule Crucible.AlertManager.Webhook do
  @moduledoc """
  Sends alert notifications via HTTP webhook using Req.
  Supports Slack, Discord, PagerDuty, and generic JSON payloads.
  """
  require Logger

  @spec send(map(), String.t(), atom()) :: :ok | {:error, term()}
  def send(alert, webhook_url, format \\ :generic) do
    payload = format_payload(alert, format)

    case Req.post(webhook_url, json: payload, receive_timeout: 10_000) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning("AlertManager webhook #{status}: #{inspect(body)}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("AlertManager webhook failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Format an alert into the given webhook payload format."
  @spec format_payload(map(), atom()) :: map()
  def format_payload(alert, :slack) do
    color =
      case alert.severity do
        :critical -> "#dc2626"
        :warning -> "#f59e0b"
        _ -> "#3b82f6"
      end

    %{
      attachments: [
        %{
          color: color,
          title: "[#{alert.severity |> to_string() |> String.upcase()}] #{alert.rule}",
          text: alert.message,
          ts: DateTime.to_unix(alert.timestamp)
        }
      ]
    }
  end

  def format_payload(alert, :discord) do
    color =
      case alert.severity do
        :critical -> 0xDC2626
        :warning -> 0xF59E0B
        _ -> 0x3B82F6
      end

    %{
      embeds: [
        %{
          title: "[#{alert.severity |> to_string() |> String.upcase()}] #{alert.rule}",
          description: alert.message,
          color: color,
          timestamp: DateTime.to_iso8601(alert.timestamp)
        }
      ]
    }
  end

  def format_payload(alert, :pagerduty) do
    severity =
      case alert.severity do
        :critical -> "critical"
        :warning -> "warning"
        _ -> "info"
      end

    routing_key =
      Application.get_env(:crucible, :alerting)[:pagerduty_routing_key] || ""

    %{
      routing_key: routing_key,
      event_action: "trigger",
      dedup_key: "#{alert.rule}-#{DateTime.to_unix(alert.timestamp)}",
      payload: %{
        summary: "[#{String.upcase(to_string(alert.severity))}] #{alert.rule}: #{alert.message}",
        source: "infra-orchestrator",
        severity: severity,
        timestamp: DateTime.to_iso8601(alert.timestamp),
        custom_details: alert[:data] || %{}
      }
    }
  end

  def format_payload(alert, :teams) do
    color =
      case alert.severity do
        :critical -> "FF0000"
        :warning -> "FFA500"
        _ -> "0078D7"
      end

    %{
      "@type" => "MessageCard",
      "@context" => "http://schema.org/extensions",
      themeColor: color,
      summary: "[#{String.upcase(to_string(alert.severity))}] #{alert.rule}",
      sections: [
        %{
          activityTitle: "[#{String.upcase(to_string(alert.severity))}] #{alert.rule}",
          facts: [
            %{name: "Severity", value: to_string(alert.severity)},
            %{name: "Rule", value: to_string(alert.rule)},
            %{name: "Time", value: DateTime.to_iso8601(alert.timestamp)}
          ],
          text: alert.message
        }
      ]
    }
  end

  def format_payload(alert, _generic) do
    %{
      severity: alert.severity,
      rule: alert.rule,
      message: alert.message,
      timestamp: DateTime.to_iso8601(alert.timestamp),
      data: alert[:data] || %{}
    }
  end
end
