defmodule CrucibleWeb.Api.HealthControllerTest do
  use CrucibleWeb.ConnCase, async: true

  setup do
    # Ensure ETS table exists for RateLimit plug (may not exist yet in async tests)
    try do
      :ets.new(:rate_limit, [:duplicate_bag, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  # Health probes return 503 when some deps aren't available in test env.
  # We test structure, not that every service is up.
  defp health_json(conn) do
    assert conn.status in [200, 503]
    Jason.decode!(conn.resp_body)
  end

  describe "GET /api/health/live" do
    test "always returns 200 with timestamp", %{conn: conn} do
      conn = get(conn, "/api/health/live")
      body = json_response(conn, 200)
      assert body["status"] == "ok"
      assert is_binary(body["timestamp"])
    end
  end

  describe "GET /api/health/ready" do
    test "returns checks array with repo, orchestrator, budget_ets", %{conn: conn} do
      conn = get(conn, "/api/health/ready")
      body = health_json(conn)

      assert body["status"] in ["ok", "degraded"]
      assert is_list(body["checks"])

      check_names = Enum.map(body["checks"], & &1["name"])
      assert "repo" in check_names
      assert "orchestrator" in check_names
      assert "budget_ets" in check_names
    end

    test "each check has name and status fields", %{conn: conn} do
      conn = get(conn, "/api/health/ready")
      body = health_json(conn)

      for check <- body["checks"] do
        assert is_binary(check["name"])
        assert check["status"] in ["ok", "error", "degraded"]
      end
    end

    test "repo check includes db_response_ms", %{conn: conn} do
      conn = get(conn, "/api/health/ready")
      body = health_json(conn)

      repo_check = Enum.find(body["checks"], &(&1["name"] == "repo"))
      assert is_number(repo_check["db_response_ms"])
      assert repo_check["db_response_ms"] >= 0
    end

    test "repo check includes pool stats when DB is available", %{conn: conn} do
      conn = get(conn, "/api/health/ready")
      body = health_json(conn)

      repo_check = Enum.find(body["checks"], &(&1["name"] == "repo"))

      if repo_check["status"] in ["ok", "degraded"] do
        assert is_map(repo_check["pool"])
        pool = repo_check["pool"]
        assert is_integer(pool["pool_size"]) or is_number(pool["pool_size"])
        assert is_integer(pool["checked_out"]) or is_number(pool["checked_out"])
        assert is_integer(pool["available"]) or is_number(pool["available"])
        assert is_number(pool["utilization"])
        assert pool["utilization"] >= 0.0 and pool["utilization"] <= 1.0
      end
    end
  end

  describe "GET /api/health/startup" do
    test "returns checks for repo, workflows, oban", %{conn: conn} do
      conn = get(conn, "/api/health/startup")
      body = health_json(conn)

      assert body["status"] in ["ok", "degraded"]
      assert is_list(body["checks"])

      check_names = Enum.map(body["checks"], & &1["name"])
      assert "repo" in check_names
      assert "workflows" in check_names
      assert "oban" in check_names
    end
  end

  describe "GET /api/v1/health" do
  @tag :skip
    test "returns the shared system health snapshot", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/health")
      body = json_response(conn, 200)

      assert body["status"] in ["ok", "degraded"]
      assert is_list(body["checks"])
      assert is_binary(body["version"])
      assert is_binary(body["commit"])
      assert body["db"] in ["connected", "unreachable"]
      assert is_map(body["budget"])
      assert is_map(body["memory"])
      assert is_map(body["savings"])
      assert is_map(body["router"])
      assert is_map(body["circuits"])
      assert is_map(body["slo"])
      assert is_map(body["runs"])
      assert is_map(body["executor"])
      assert is_map(body["dataFeeds"])
      assert is_map(body["monitoring"])
      assert Map.has_key?(body["budget"], "dailySpent")
      assert Map.has_key?(body["budget"], "dailyLimit")
      assert Map.has_key?(body["budget"], "eventCount")
      assert Map.has_key?(body["memory"], "totalNotes")
      assert Map.has_key?(body["memory"], "staleNotes")
      assert Map.has_key?(body["savings"], "totalSavedRatio")
      assert Map.has_key?(body["savings"], "totalSavedTokens")
      assert Map.has_key?(body["slo"], "requestCount")
      assert Map.has_key?(body["slo"], "healthRoute")
      assert Map.has_key?(body["runs"], "total")
      assert Map.has_key?(body["runs"], "active")
      assert Map.has_key?(body["executor"], "instanceCount")
      assert Map.has_key?(body["dataFeeds"], "entries")
      assert Map.has_key?(body["monitoring"], "grafanaUrl")
    end

    test "includes all check categories", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/health")
      body = json_response(conn, 200)

      check_names = Enum.map(body["checks"], & &1["name"])
      assert "repo" in check_names
      assert "orchestrator" in check_names
      assert "budget_ets" in check_names
      assert "workflows" in check_names
      assert "oban" in check_names
    end
  end

  describe "GET /api/health/executor" do
    test "returns executor snapshot", %{conn: conn} do
      conn = get(conn, "/api/health/executor")
      body = json_response(conn, 200)

      assert is_boolean(body["natsConnected"])
      assert is_integer(body["instanceCount"])
      assert is_list(body["instances"])
    end
  end
end
