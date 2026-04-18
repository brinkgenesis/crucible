defmodule CrucibleWeb.TenantControllerTest do
  use CrucibleWeb.ConnCase, async: false

  @tenant_id "test-tenant-abc"

  defp authed_tenant_conn(conn) do
    conn
    |> authenticate()
    |> put_req_header("x-tenant-id", @tenant_id)
  end

  describe "GET /api/tenants/:tenant_id/budget" do
    test "returns budget for matching tenant", %{conn: conn} do
      conn =
        conn
        |> authed_tenant_conn()
        |> get("/api/tenants/#{@tenant_id}/budget")

      body = json_response(conn, 200)
      assert body["tenant_id"] == @tenant_id
      assert Map.has_key?(body, "daily_spent")
      assert Map.has_key?(body, "daily_limit")
      assert Map.has_key?(body, "daily_remaining")
      assert is_boolean(body["is_over_budget"])
    end

    test "returns 403 when x-tenant-id header does not match path", %{conn: conn} do
      conn =
        conn
        |> authenticate()
        |> put_req_header("x-tenant-id", "different-tenant")
        |> get("/api/tenants/#{@tenant_id}/budget")

      body = json_response(conn, 403)
      assert body["error"] == "tenant_id mismatch"
    end

    test "returns 400 when x-tenant-id header is missing", %{conn: conn} do
      conn =
        conn
        |> authenticate()
        |> get("/api/tenants/#{@tenant_id}/budget")

      # TenantId plug rejects requests without the header
      assert conn.status == 400
    end
  end

  describe "DELETE /api/tenants/:tenant_id" do
    test "returns 404 when tenant does not exist", %{conn: conn} do
      nonexistent = "tenant-does-not-exist-#{System.unique_integer([:positive])}"

      conn =
        conn
        |> authenticate()
        |> put_req_header("x-tenant-id", nonexistent)
        |> delete("/api/tenants/#{nonexistent}")

      body = json_response(conn, 404)
      assert body["error"] == "tenant not found"
    end

    test "returns 403 when x-tenant-id header does not match path", %{conn: conn} do
      conn =
        conn
        |> authenticate()
        |> put_req_header("x-tenant-id", "wrong-tenant")
        |> delete("/api/tenants/#{@tenant_id}")

      body = json_response(conn, 403)
      assert body["error"] == "tenant_id mismatch"
    end
  end

  describe "POST /api/tenants/:tenant_id/runs" do
    test "returns 403 when x-tenant-id header does not match path", %{conn: conn} do
      conn =
        conn
        |> authenticate()
        |> put_req_header("x-tenant-id", "different-tenant")
        |> post("/api/tenants/#{@tenant_id}/runs", %{workflow: "test"})

      body = json_response(conn, 403)
      assert body["error"] == "tenant_id mismatch"
    end

    test "returns 400 when x-tenant-id header is missing", %{conn: conn} do
      conn =
        conn
        |> authenticate()
        |> post("/api/tenants/#{@tenant_id}/runs", %{workflow: "test"})

      assert conn.status == 400
    end
  end
end
