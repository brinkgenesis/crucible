defmodule CrucibleWeb.Plugs.CORS do
  @moduledoc """
  CORS plug for API routes.

  Allows configurable origins (defaults to localhost).
  """
  import Plug.Conn

  @behaviour Plug

  @default_origins Application.compile_env(
                     :crucible,
                     :cors_origins,
                     ["http://localhost:4801", "http://localhost:3000"]
                   )

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "OPTIONS"} = conn, _opts) do
    conn
    |> put_cors_headers()
    |> send_resp(204, "")
    |> halt()
  end

  def call(conn, _opts) do
    put_cors_headers(conn)
  end

  defp put_cors_headers(conn) do
    origin = get_req_header(conn, "origin") |> List.first("")
    allowed = allowed_origins()
    is_wildcard = "*" in allowed

    if origin in allowed or is_wildcard do
      conn
      |> put_resp_header(
        "access-control-allow-origin",
        if(is_wildcard, do: "*", else: origin)
      )
      |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, DELETE, PATCH, OPTIONS")
      |> put_resp_header(
        "access-control-allow-headers",
        "authorization, content-type, x-client-id, x-tenant-id, x-request-id"
      )
      |> then(fn c ->
        # Per spec: credentials cannot be used with wildcard origin
        if is_wildcard,
          do: c,
          else: put_resp_header(c, "access-control-allow-credentials", "true")
      end)
      |> put_resp_header("access-control-expose-headers", "x-request-id, x-tenant-id")
      |> put_resp_header("access-control-max-age", "86400")
      |> put_resp_header("vary", "Origin")
    else
      conn
      |> put_resp_header("vary", "Origin")
    end
  end

  defp allowed_origins do
    origins =
      case Application.get_env(:crucible, :cors_origins) do
        nil ->
          @default_origins

        origins when is_list(origins) ->
          origins

        origin when is_binary(origin) ->
          origin |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
      end

    # Reject wildcard in production — explicit origins required
    if "*" in origins and Application.get_env(:crucible, :config_env) == :prod do
      require Logger

      Logger.error(
        "CORS: wildcard '*' is not allowed in production. Set CORS_ALLOWED_ORIGINS to explicit origins."
      )

      origins -- ["*"]
    else
      origins
    end
  end
end
