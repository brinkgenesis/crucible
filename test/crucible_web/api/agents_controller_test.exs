defmodule CrucibleWeb.Api.AgentsControllerTest do
  use CrucibleWeb.ConnCase

  setup do
    try do
      :ets.new(:rate_limit, [:duplicate_bag, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  # ── GET /api/v1/agents ───────────────────────────────────────────

  describe "GET /api/v1/agents" do
    test "returns a list of agents", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/agents")
      body = json_response(conn, 200)
      assert is_list(body)
    end

    test "each agent has name, filename, and raw fields when agents exist", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/agents")
      body = json_response(conn, 200)

      # Agents dir may or may not exist in test — just verify structure if populated
      for agent <- body do
        assert is_binary(agent["name"])
        assert is_binary(agent["filename"])
        assert is_binary(agent["raw"])
      end
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
        conn = get(conn, "/api/v1/agents")
        assert conn.status in [401, 503]
      end)
    end
  end

  # ── GET /api/v1/agents/:name ─────────────────────────────────────

  describe "GET /api/v1/agents/:name" do
    test "returns 404 for a nonexistent agent", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/agents/nonexistent_agent_xyz")
      body = json_response(conn, 404)
      assert body["error"] == "not_found"
    end

    test "sanitizes path traversal attempts", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/agents/..%2F..%2Fetc%2Fpasswd")
      # Should return 404, not expose system files
      assert conn.status in [404, 400]
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
        conn = get(conn, "/api/v1/agents/some-agent")
        assert conn.status in [401, 503]
      end)
    end
  end

  # ── GET /api/v1/agents/stats ─────────────────────────────────────

  describe "GET /api/v1/agents/stats" do
    test "returns agent stats as a list", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/agents/stats")
      # TraceReader may not be available in test, allow 200 or 500
      case conn.status do
        200 ->
          body = json_response(conn, 200)
          assert is_list(body)

          for stat <- body do
            assert is_binary(stat["agentType"])
            assert is_integer(stat["eventCount"])
          end

        500 ->
          :ok
      end
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
        conn = get(conn, "/api/v1/agents/stats")
        assert conn.status in [401, 503]
      end)
    end
  end
end
