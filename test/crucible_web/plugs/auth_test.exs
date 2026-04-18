defmodule CrucibleWeb.Plugs.AuthTest do
  use CrucibleWeb.ConnCase, async: true

  alias CrucibleWeb.Plugs.Auth

  describe "call/2" do
    test "allows requests with valid Bearer token" do
      api_key = Application.get_env(:crucible, :api_key)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> Auth.call([])

      refute conn.halted
    end

    test "blocks requests without token when API key configured" do
      conn = build_conn() |> Auth.call([])
      assert conn.halted
      assert conn.status == 401
    end

    test "rejects invalid Bearer token" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer wrong-key")
        |> Auth.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "allows requests when no API key configured (dev mode)" do
      conn =
        build_conn()
        |> Plug.Conn.put_private(:override_api_key, nil)
        |> Auth.call([])

      refute conn.halted
    end
  end
end
