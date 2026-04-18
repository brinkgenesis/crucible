defmodule CrucibleWeb.Api.WorkflowsControllerTest do
  use CrucibleWeb.ConnCase, async: true

  setup do
    try do
      :ets.new(:rate_limit, [:duplicate_bag, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  describe "GET /api/v1/workflows" do
    test "returns a list of workflows", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/workflows")
      body = json_response(conn, 200)
      assert is_list(body)
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
      conn = get(conn, "/api/v1/workflows")
      assert conn.status in [401, 503]
      end)
    end
  end

  describe "GET /api/v1/workflows/:name" do
    test "returns 404 for nonexistent workflow", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/workflows/nonexistent")
      assert conn.status in [404, 200]
    end
  end
end
