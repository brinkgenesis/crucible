defmodule Crucible.AlertManagerTest do
  use ExUnit.Case, async: false

  alias Crucible.AlertManager
  alias Crucible.Events

  @test_rules [
    %{
      name: :run_failed,
      event_type: :run_failed,
      severity: :warning,
      cooldown_ms: 100,
      message: "Run {run_id} failed: {reason}"
    },
    %{
      name: :run_exhausted,
      event_type: :run_exhausted,
      severity: :warning,
      cooldown_ms: 100,
      message: "Run {run_id} exhausted all retries"
    }
  ]

  setup do
    prev = Application.get_env(:crucible, :alerting)

    Application.put_env(:crucible, :alerting,
      enabled: true,
      webhook_url: nil,
      webhook_format: :generic,
      cooldown_ms: 100
    )

    # Start a test-named AlertManager with short-cooldown rules
    {:ok, pid} = AlertManager.start_link(name: :test_alert_manager, rules: @test_rules)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      if prev, do: Application.put_env(:crucible, :alerting, prev)
    end)

    %{pid: pid}
  end

  test "evaluates matching rule on alert event", %{pid: pid} do
    Events.broadcast_alert_event(:run_failed, %{run_id: "test-123", reason: "timeout"})
    Process.sleep(50)

    history = AlertManager.alert_history(pid)
    assert length(history) == 1

    alert = hd(history)
    assert alert.rule == :run_failed
    assert alert.severity == :warning
    assert String.contains?(alert.message, "test-123")
    assert String.contains?(alert.message, "timeout")
  end

  test "cooldown deduplication suppresses repeated alerts", %{pid: pid} do
    Events.broadcast_alert_event(:run_failed, %{run_id: "run-1", reason: "error"})
    Process.sleep(20)
    Events.broadcast_alert_event(:run_failed, %{run_id: "run-2", reason: "error"})
    Process.sleep(50)

    history = AlertManager.alert_history(pid)
    assert length(history) == 1
    assert hd(history).data.run_id == "run-1"
  end

  test "cooldown expiry allows same alert type again", %{pid: pid} do
    Events.broadcast_alert_event(:run_failed, %{run_id: "run-1", reason: "error"})
    Process.sleep(150)
    Events.broadcast_alert_event(:run_failed, %{run_id: "run-2", reason: "error"})
    Process.sleep(50)

    history = AlertManager.alert_history(pid)
    assert length(history) == 2
  end

  test "different event types are independent for cooldown", %{pid: pid} do
    Events.broadcast_alert_event(:run_failed, %{run_id: "run-1", reason: "error"})
    Process.sleep(20)
    Events.broadcast_alert_event(:run_exhausted, %{run_id: "run-1"})
    Process.sleep(50)

    history = AlertManager.alert_history(pid)
    assert length(history) == 2
    rules = Enum.map(history, & &1.rule)
    assert :run_failed in rules
    assert :run_exhausted in rules
  end

  test "unmatched event types produce no alerts", %{pid: pid} do
    Events.broadcast_alert_event(:unknown_event, %{foo: "bar"})
    Process.sleep(50)

    assert AlertManager.alert_history(pid) == []
  end

  test "alert_history respects limit", %{pid: pid} do
    Events.broadcast_alert_event(:run_failed, %{run_id: "r1", reason: "e"})
    Process.sleep(20)
    Events.broadcast_alert_event(:run_exhausted, %{run_id: "r2"})
    Process.sleep(50)

    assert length(AlertManager.alert_history(pid, 1)) == 1
    assert length(AlertManager.alert_history(pid, 10)) == 2
  end
end
