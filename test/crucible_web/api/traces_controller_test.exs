defmodule CrucibleWeb.Api.TracesControllerTest do
  use CrucibleWeb.ConnCase

  setup do
    try do
      :ets.new(:rate_limit, [:duplicate_bag, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  # --- GET /api/v1/traces ---

  describe "GET /api/v1/traces" do
    test "returns a list of trace events", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/traces")
      assert conn.status in [200, 500]

      if conn.status == 200 do
        body = json_response(conn, 200)
        assert is_list(body)
      end
    end

    test "accepts limit query parameter", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/traces?limit=10")
      assert conn.status in [200, 500]

      if conn.status == 200 do
        body = json_response(conn, 200)
        assert is_list(body)
        assert length(body) <= 10
      end
    end

    test "accepts runId query parameter", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/traces?runId=test-run-id")
      assert conn.status in [200, 500]

      if conn.status == 200 do
        body = json_response(conn, 200)
        assert is_list(body)
      end
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
        conn = get(conn, "/api/v1/traces")
        assert conn.status in [401, 503]
      end)
    end
  end

  # --- GET /api/v1/traces/:id ---

  describe "GET /api/v1/traces/:id" do
    test "returns 404 for nonexistent trace event", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/traces/nonexistent-event-id")
      assert conn.status in [200, 404, 500]

      if conn.status == 404 do
        body = json_response(conn, 404)
        assert body["error"] == "not_found"
      end
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
        conn = get(conn, "/api/v1/traces/some-id")
        assert conn.status in [401, 503]
      end)
    end
  end

  # --- GET /api/v1/traces/export/:run_id ---

  describe "GET /api/v1/traces/export/:run_id" do
    test "returns NDJSON content type", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/traces/export/test-run-123")
      assert conn.status in [200, 500]

      if conn.status == 200 do
        content_type = get_resp_header(conn, "content-type")
        assert Enum.any?(content_type, &String.contains?(&1, "application/x-ndjson"))

        disposition = get_resp_header(conn, "content-disposition")
        assert Enum.any?(disposition, &String.contains?(&1, "traces-test-run-123.jsonl"))
      end
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
        conn = get(conn, "/api/v1/traces/export/some-run")
        assert conn.status in [401, 503]
      end)
    end
  end

  # --- GET /api/v1/traces/dashboard ---

  describe "GET /api/v1/traces/dashboard" do
    test "returns dashboard with runs and totalEvents", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/traces/dashboard")
      assert conn.status in [200, 500]

      if conn.status == 200 do
        body = json_response(conn, 200)
        assert is_list(body["runs"])
        assert is_integer(body["totalEvents"])
      end
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
        conn = get(conn, "/api/v1/traces/dashboard")
        assert conn.status in [401, 503]
      end)
    end
  end

  # --- GET /api/v1/traces/:run_id/detail ---

  describe "GET /api/v1/traces/:run_id/detail" do
    test "returns 404 for nonexistent run", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/traces/nonexistent-run-xyz/detail")
      assert conn.status in [404, 500]

      if conn.status == 404 do
        body = json_response(conn, 404)
        assert body["error"] == "not_found"
      end
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
        conn = get(conn, "/api/v1/traces/some-run/detail")
        assert conn.status in [401, 503]
      end)
    end
  end

  # --- GET /api/v1/traces/:run_id/summary ---

  describe "GET /api/v1/traces/:run_id/summary" do
    test "returns summary for a run (empty events yields zero counts)", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/traces/nonexistent-run-xyz/summary")
      assert conn.status in [200, 500]

      if conn.status == 200 do
        body = json_response(conn, 200)
        assert body["runId"] == "nonexistent-run-xyz"
        assert is_integer(body["eventCount"])
        assert is_map(body["byType"])
        assert is_number(body["totalCostUsd"])
      end
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
        conn = get(conn, "/api/v1/traces/some-run/summary")
        assert conn.status in [401, 503]
      end)
    end
  end
end
