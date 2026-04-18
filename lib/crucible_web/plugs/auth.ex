defmodule CrucibleWeb.Plugs.Auth do
  @moduledoc """
  Authentication plug for API routes.

  Validates Bearer token against the configured API key.
  In production, requests are rejected when no API key is configured (fail-closed).
  In dev/test, requests pass through when no API key is configured.
  """
  import Plug.Conn
  require Logger

  @behaviour Plug

  @spec init(keyword()) :: keyword()
  @impl true
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  @impl true
  def call(conn, _opts) do
    case configured_api_key(conn) do
      nil ->
        if production?() do
          Logger.error("Auth: no API key configured in production — rejecting request")

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            503,
            Jason.encode!(%{error: "misconfigured", message: "API authentication not configured"})
          )
          |> halt()
        else
          # Dev/test: no API key configured — assign a dev-mode partner user
          # so that RBAC doesn't reject with 401 for missing current_user
          assign(conn, :current_user, %{id: "dev", role: "admin", email: "dev@localhost"})
        end

      key ->
        validate_token(conn, key)
    end
  end

  defp configured_api_key(conn) do
    case conn.private do
      %{override_api_key: key} -> key
      _ -> Application.get_env(:crucible, :api_key)
    end
  end

  defp production? do
    Application.get_env(:crucible, :config_env) == :prod
  end

  defp validate_token(conn, expected_key) do
    token =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> t] -> t
        _ -> nil
      end

    if token != nil and Plug.Crypto.secure_compare(token, expected_key) do
      conn
    else
      :telemetry.execute(
        [:crucible, :auth, :failure],
        %{count: 1},
        %{ip: to_string(:inet.ntoa(conn.remote_ip)), path: conn.request_path, method: conn.method}
      )

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
      |> halt()
    end
  end
end
