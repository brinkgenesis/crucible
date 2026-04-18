defmodule Crucible.AlertManager.WebhookTest do
  use ExUnit.Case, async: true

  alias Crucible.AlertManager.Webhook

  @sample_alert %{
    severity: :critical,
    rule: :budget_exceeded,
    message: "Daily budget exceeded: $95 of $100",
    timestamp: ~U[2026-03-10 12:00:00Z],
    data: %{spent: 95, limit: 100}
  }

  describe "format_payload/2" do
    test "slack format has attachments with color" do
      payload = Webhook.format_payload(@sample_alert, :slack)
      assert Map.has_key?(payload, :attachments)
      [att] = payload.attachments
      assert att.color == "#dc2626"
      assert String.contains?(att.title, "CRITICAL")
      assert att.text == @sample_alert.message
    end

    test "discord format has embeds with color" do
      payload = Webhook.format_payload(@sample_alert, :discord)
      assert Map.has_key?(payload, :embeds)
      [embed] = payload.embeds
      assert embed.color == 0xDC2626
      assert String.contains?(embed.title, "CRITICAL")
      assert embed.description == @sample_alert.message
    end

    test "generic format has flat structure" do
      payload = Webhook.format_payload(@sample_alert, :generic)
      assert payload.severity == :critical
      assert payload.rule == :budget_exceeded
      assert payload.message == @sample_alert.message
      assert Map.has_key?(payload, :timestamp)
    end

    test "warning severity uses correct slack color" do
      alert = %{@sample_alert | severity: :warning}
      payload = Webhook.format_payload(alert, :slack)
      [att] = payload.attachments
      assert att.color == "#f59e0b"
    end

    test "warning severity uses correct discord color" do
      alert = %{@sample_alert | severity: :warning}
      payload = Webhook.format_payload(alert, :discord)
      [embed] = payload.embeds
      assert embed.color == 0xF59E0B
    end

    test "pagerduty format has routing_key and payload" do
      payload = Webhook.format_payload(@sample_alert, :pagerduty)
      assert payload.event_action == "trigger"
      assert is_binary(payload.routing_key)
      assert is_binary(payload.dedup_key)
      assert payload.payload.severity == "critical"
      assert payload.payload.source == "infra-orchestrator"
      assert String.contains?(payload.payload.summary, "CRITICAL")
    end

    test "pagerduty warning maps to warning severity" do
      alert = %{@sample_alert | severity: :warning}
      payload = Webhook.format_payload(alert, :pagerduty)
      assert payload.payload.severity == "warning"
    end

    test "teams format has MessageCard structure" do
      payload = Webhook.format_payload(@sample_alert, :teams)
      assert payload["@type"] == "MessageCard"
      assert payload.themeColor == "FF0000"
      [section] = payload.sections
      assert String.contains?(section.activityTitle, "CRITICAL")
      assert section.text == @sample_alert.message
    end
  end
end
