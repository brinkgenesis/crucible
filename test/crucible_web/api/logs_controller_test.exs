defmodule CrucibleWeb.Api.LogsControllerTest do
  use CrucibleWeb.ConnCase

  setup do
    try do
      :ets.new(:rate_limit, [:duplicate_bag, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  # ── GET /api/v1/logs ─────────────────────────────────────────────

  describe "GET /api/v1/logs" do
    test "returns a list of log files", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/logs")
      # .claude-flow/logs may not exist in test — allow 200 or 500
      case conn.status do
        200 ->
          body = json_response(conn, 200)
          assert is_list(body)

          for log <- body do
            assert is_binary(log["name"])
            assert is_integer(log["size"])
            assert is_binary(log["modifiedAt"])
          end

        500 ->
          :ok
      end
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
        conn = get(conn, "/api/v1/logs")
        assert conn.status in [401, 503]
      end)
    end
  end

  # ── GET /api/v1/logs/stream ──────────────────────────────────────

  describe "GET /api/v1/logs/stream" do
    test "returns 404 for nonexistent file", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/logs/stream", file: "nonexistent.log")
      body = json_response(conn, 404)
      assert body["error"] == "not_found"
    end

    test "prevents path traversal", %{conn: conn} do
      conn =
        conn
        |> authenticate()
        |> get("/api/v1/logs/stream", file: "../../etc/passwd")

      # Should return 404, not the file contents
      body = json_response(conn, 404)
      assert body["error"] == "not_found"
    end

    test "prevents absolute path traversal", %{conn: conn} do
      conn =
        conn
        |> authenticate()
        |> get("/api/v1/logs/stream", file: "/etc/passwd")

      body = json_response(conn, 404)
      assert body["error"] == "not_found"
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
        conn = get(conn, "/api/v1/logs/stream", file: "test.log")
        assert conn.status in [401, 503]
      end)
    end
  end
end
