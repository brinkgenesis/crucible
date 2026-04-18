defmodule CrucibleWeb.Plugs.CORSTest do
  use CrucibleWeb.ConnCase, async: true

  alias CrucibleWeb.Plugs.CORS

  @allowed_origin "http://localhost:3000"
  @disallowed_origin "http://evil.com"

  describe "OPTIONS preflight" do
    test "returns 204 with CORS headers for allowed origin" do
      conn =
        build_conn(:options, "/api/health")
        |> put_req_header("origin", @allowed_origin)
        |> CORS.call([])

      assert conn.halted
      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == [@allowed_origin]
      assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]

      assert get_resp_header(conn, "access-control-expose-headers") == [
               "x-request-id, x-tenant-id"
             ]

      assert get_resp_header(conn, "vary") == ["Origin"]
    end

    test "returns 204 without CORS allow-origin for disallowed origin" do
      conn =
        build_conn(:options, "/api/health")
        |> put_req_header("origin", @disallowed_origin)
        |> CORS.call([])

      assert conn.halted
      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end

  describe "normal requests" do
    test "adds CORS headers for allowed origin" do
      conn =
        build_conn(:get, "/api/health")
        |> put_req_header("origin", @allowed_origin)
        |> CORS.call([])

      refute conn.halted
      assert get_resp_header(conn, "access-control-allow-origin") == [@allowed_origin]
      assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]

      [methods] = get_resp_header(conn, "access-control-allow-methods")
      assert String.contains?(methods, "PATCH")
    end

    test "skips CORS allow-origin for disallowed origin" do
      conn =
        build_conn(:get, "/api/health")
        |> put_req_header("origin", @disallowed_origin)
        |> CORS.call([])

      refute conn.halted
      assert get_resp_header(conn, "access-control-allow-origin") == []
      # Vary: Origin should still be present
      assert get_resp_header(conn, "vary") == ["Origin"]
    end

    test "allowed headers include x-tenant-id and x-request-id" do
      conn =
        build_conn(:get, "/api/health")
        |> put_req_header("origin", @allowed_origin)
        |> CORS.call([])

      [headers] = get_resp_header(conn, "access-control-allow-headers")
      assert String.contains?(headers, "x-tenant-id")
      assert String.contains?(headers, "x-request-id")
    end
  end
end
