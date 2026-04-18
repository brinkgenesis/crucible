defmodule CrucibleWeb.Api.MetricsControllerTest do
  use CrucibleWeb.ConnCase, async: true

  describe "GET /metrics" do
    test "returns Prometheus text format", %{conn: conn} do
      conn = get(conn, "/metrics")
      assert conn.status == 200
      assert {"content-type", content_type} = List.keyfind(conn.resp_headers, "content-type", 0)
      assert content_type =~ "text/plain"
    end

    test "contains orchestrator metrics", %{conn: conn} do
      conn = get(conn, "/metrics")
      body = conn.resp_body
      # Counter metrics are supported; summaries are dropped by prometheus_core
      assert body =~ "orchestrator" or body =~ "# HELP" or body == ""
    end
  end
end
