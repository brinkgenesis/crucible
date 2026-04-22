defmodule CrucibleWeb.Api.RunsControllerTest do
  use CrucibleWeb.ConnCase

  setup do
    try do
      :ets.new(:rate_limit, [:duplicate_bag, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  describe "GET /api/v1/runs" do
    test "returns paginated runs", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/runs")
      body = json_response(conn, 200)
      assert is_list(body["data"])
      assert is_map(body["pagination"])
      assert Map.has_key?(body["pagination"], "total")
      assert Map.has_key?(body["pagination"], "hasMore")
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
        conn = get(conn, "/api/v1/runs")
        assert conn.status in [401, 503]
      end)
    end
  end

  describe "GET /api/v1/runs/:id" do
    test "returns 404 for nonexistent run", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/runs/nonexistent-id")
      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
    end
  end

  describe "GET /api/v1/runs/sessions" do
    test "returns a list of sessions", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/runs/sessions")
      body = json_response(conn, 200)
      assert is_list(body)
    end
  end
end
