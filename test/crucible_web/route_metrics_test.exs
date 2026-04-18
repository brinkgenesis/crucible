defmodule CrucibleWeb.RouteMetricsTest do
  use ExUnit.Case, async: false

  alias CrucibleWeb.RouteMetrics

  test "snapshot returns defaults when metrics process is unavailable" do
    pid = Process.whereis(RouteMetrics)

    if pid do
      Process.exit(pid, :kill)
      wait_until_down(RouteMetrics)
    end

    snapshot = RouteMetrics.snapshot()

    assert snapshot["totalRequests"] == 0
    assert snapshot["totalErrors"] == 0
    assert snapshot["errorRate"] == 0.0
    assert snapshot["routes"] == []
    assert snapshot["alerts"] == []

    assert RouteMetrics.sample_count() == 0
    assert :ok = RouteMetrics.reset()
    assert :ok = RouteMetrics.record("GET", "/api/health", 200, 12.5)
  end

  defp wait_until_down(name, attempts \\ 20)
  defp wait_until_down(_name, 0), do: :ok

  defp wait_until_down(name, attempts) do
    if Process.whereis(name) do
      Process.sleep(10)
      wait_until_down(name, attempts - 1)
    else
      :ok
    end
  end
end
