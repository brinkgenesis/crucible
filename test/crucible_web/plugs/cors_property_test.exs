defmodule CrucibleWeb.Plugs.CORSPropertyTest do
  use CrucibleWeb.ConnCase, async: true
  use ExUnitProperties

  alias CrucibleWeb.Plugs.CORS

  @default_origins ["http://localhost:4801", "http://localhost:3000"]

  defp allowed_origin do
    member_of(@default_origins)
  end

  defp disallowed_origin do
    gen all(
          host <- string(:alphanumeric, min_length: 3, max_length: 15),
          port <- integer(5000..9999)
        ) do
      "http://#{host}:#{port}"
    end
  end

  defp conn_with_origin(method, origin) do
    build_conn(method, "/api/test")
    |> put_req_header("origin", origin)
  end

  setup do
    # Ensure we use default origins (no app config override)
    previous = Application.get_env(:crucible, :cors_origins)
    Application.delete_env(:crucible, :cors_origins)

    on_exit(fn ->
      if previous do
        Application.put_env(:crucible, :cors_origins, previous)
      else
        Application.delete_env(:crucible, :cors_origins)
      end
    end)

    :ok
  end

  describe "allowed origins" do
    property "allowed origins get CORS headers" do
      check all(origin <- allowed_origin()) do
        conn = conn_with_origin(:get, origin) |> CORS.call([])

        assert get_resp_header(conn, "access-control-allow-origin") == [origin]
        assert get_resp_header(conn, "access-control-allow-methods") != []
        assert get_resp_header(conn, "access-control-allow-headers") != []
        assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
        assert get_resp_header(conn, "access-control-max-age") == ["86400"]
        assert get_resp_header(conn, "vary") == ["Origin"]
      end
    end
  end

  describe "disallowed origins" do
    property "disallowed origins don't get access-control-allow-origin header" do
      check all(origin <- disallowed_origin()) do
        conn = conn_with_origin(:get, origin) |> CORS.call([])

        assert get_resp_header(conn, "access-control-allow-origin") == [],
               "Disallowed origin #{origin} should not get CORS allow-origin header"

        # Vary: Origin is still set for cache correctness
        assert get_resp_header(conn, "vary") == ["Origin"]
      end
    end
  end

  describe "OPTIONS requests" do
    property "OPTIONS requests with allowed origins halt the connection with CORS headers" do
      check all(origin <- allowed_origin()) do
        conn = conn_with_origin(:options, origin) |> CORS.call([])

        assert conn.halted, "OPTIONS requests should halt the connection"
        assert conn.status == 204
        assert get_resp_header(conn, "access-control-allow-origin") == [origin]
        assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
      end
    end

    property "OPTIONS requests with disallowed origins still halt but without allow-origin" do
      check all(origin <- disallowed_origin()) do
        conn = conn_with_origin(:options, origin) |> CORS.call([])

        assert conn.halted, "OPTIONS requests should always halt"
        assert conn.status == 204
        assert get_resp_header(conn, "access-control-allow-origin") == []
      end
    end
  end
end
