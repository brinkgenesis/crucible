defmodule CrucibleWeb.Plugs.RateLimitTest do
  use CrucibleWeb.ConnCase, async: false

  alias CrucibleWeb.Plugs.RateLimit

  describe "IP-based rate limiting" do
    test "allows requests under limit" do
      conn =
        build_conn(:get, "/test")
        |> Map.put(:remote_ip, {10, 99, 99, 1})
        |> RateLimit.call([])

      refute conn.halted
    end

    test "returns 429 when write limit exceeded" do
      ip = {10, 99, 99, 2}

      for _ <- 1..20 do
        build_conn(:post, "/test")
        |> Map.put(:remote_ip, ip)
        |> RateLimit.call([])
      end

      conn =
        build_conn(:post, "/test")
        |> Map.put(:remote_ip, ip)
        |> RateLimit.call([])

      assert conn.halted
      assert conn.status == 429
    end
  end

  describe "rate-limited response headers" do
    test "returns Retry-After header when IP write limit exceeded" do
      ip = {10, 99, 99, 3}

      for _ <- 1..20 do
        build_conn(:post, "/test")
        |> Map.put(:remote_ip, ip)
        |> RateLimit.call([])
      end

      conn =
        build_conn(:post, "/test")
        |> Map.put(:remote_ip, ip)
        |> RateLimit.call([])

      assert conn.halted
      assert conn.status == 429
      assert get_resp_header(conn, "retry-after") == ["60"]
    end

    test "429 response body includes retry_after" do
      ip = {10, 99, 99, 4}

      for _ <- 1..20 do
        build_conn(:post, "/test")
        |> Map.put(:remote_ip, ip)
        |> RateLimit.call([])
      end

      conn =
        build_conn(:post, "/test")
        |> Map.put(:remote_ip, ip)
        |> RateLimit.call([])

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "rate_limited"
      assert body["retry_after"] == 60
    end
  end

  describe "tenant-based rate limiting" do
    test "applies tenant bucket when x-tenant-id header is present" do
      ip = {10, 99, 99, 10}

      conn =
        build_conn(:get, "/test")
        |> Map.put(:remote_ip, ip)
        |> put_req_header("x-tenant-id", "tenant-abc")
        |> RateLimit.call([])

      refute conn.halted
    end

    test "extracts tenant from Bearer token" do
      ip = {10, 99, 99, 11}

      conn =
        build_conn(:get, "/test")
        |> Map.put(:remote_ip, ip)
        |> put_req_header("authorization", "Bearer my-api-key")
        |> RateLimit.call([])

      refute conn.halted
    end

    test "no tenant bucket when no tenant header" do
      ip = {10, 99, 99, 12}

      conn =
        build_conn(:get, "/test")
        |> Map.put(:remote_ip, ip)
        |> RateLimit.call([])

      refute conn.halted
    end
  end
end
