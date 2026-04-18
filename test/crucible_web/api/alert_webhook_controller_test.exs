defmodule CrucibleWeb.Api.AlertWebhookControllerTest do
  use CrucibleWeb.ConnCase, async: true

  alias Crucible.Events

  @alertmanager_payload %{
    "status" => "firing",
    "alerts" => [
      %{
        "status" => "firing",
        "labels" => %{
          "alertname" => "DailyCostCritical",
          "severity" => "critical"
        },
        "annotations" => %{
          "summary" => "Daily cost near limit",
          "description" => "Daily spend has exceeded $90"
        },
        "startsAt" => "2026-03-17T12:00:00Z",
        "endsAt" => "0001-01-01T00:00:00Z"
      }
    ]
  }

  setup do
    Events.subscribe_alert_feed()
    :ok
  end

  describe "POST /api/v1/webhooks/alert" do
    test "accepts valid alertmanager payload", %{conn: conn} do
      conn = post(conn, "/api/v1/webhooks/alert", @alertmanager_payload)
      body = json_response(conn, 200)

      assert body["status"] == "ok"
      assert body["processed"] == 1
      assert hd(body["alerts"])["alertname"] == "DailyCostCritical"
      assert hd(body["alerts"])["status"] == "firing"
    end

    test "broadcasts alert event to PubSub", %{conn: conn} do
      post(conn, "/api/v1/webhooks/alert", @alertmanager_payload)

      assert_receive {:alert_event, :budget_exceeded, data}, 1000
      assert data.alertname == "DailyCostCritical"
      assert data.severity == "critical"
      assert data.source == :alertmanager
    end

    test "handles multiple alerts in single payload", %{conn: conn} do
      payload = %{
        "alerts" => [
          %{
            "status" => "firing",
            "labels" => %{"alertname" => "DailyCostWarning", "severity" => "warning"},
            "annotations" => %{"summary" => "Cost warning"},
            "startsAt" => "2026-03-17T12:00:00Z"
          },
          %{
            "status" => "firing",
            "labels" => %{"alertname" => "ServiceDown", "severity" => "critical"},
            "annotations" => %{"summary" => "Service down"},
            "startsAt" => "2026-03-17T12:01:00Z"
          }
        ]
      }

      conn = post(conn, "/api/v1/webhooks/alert", payload)
      body = json_response(conn, 200)

      assert body["processed"] == 2

      assert_receive {:alert_event, :budget_warning, _}, 1000
      assert_receive {:alert_event, :circuit_breaker_open, _}, 1000
    end

    test "maps resolved alerts", %{conn: conn} do
      payload = %{
        "alerts" => [
          %{
            "status" => "resolved",
            "labels" => %{"alertname" => "HighLatency", "severity" => "warning"},
            "annotations" => %{"summary" => "Latency back to normal"},
            "startsAt" => "2026-03-17T12:00:00Z",
            "endsAt" => "2026-03-17T12:30:00Z"
          }
        ]
      }

      conn = post(conn, "/api/v1/webhooks/alert", payload)
      body = json_response(conn, 200)

      assert body["status"] == "ok"
      assert hd(body["alerts"])["status"] == "resolved"

      assert_receive {:alert_event, :high_latency, data}, 1000
      assert data.status == "resolved"
    end

    test "maps unknown alertnames to :prometheus_alert", %{conn: conn} do
      payload = %{
        "alerts" => [
          %{
            "status" => "firing",
            "labels" => %{"alertname" => "CustomAlertXyz", "severity" => "info"},
            "annotations" => %{},
            "startsAt" => "2026-03-17T12:00:00Z"
          }
        ]
      }

      post(conn, "/api/v1/webhooks/alert", payload)

      assert_receive {:alert_event, :prometheus_alert, data}, 1000
      assert data.alertname == "CustomAlertXyz"
    end

    test "rejects payload without alerts array", %{conn: conn} do
      conn = post(conn, "/api/v1/webhooks/alert", %{"foo" => "bar"})
      body = json_response(conn, 400)

      assert body["error"] == "bad_request"
    end
  end
end
