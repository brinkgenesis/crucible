defmodule CrucibleWeb.SessionController do
  @moduledoc """
  Handles OAuth2 login flow and session management.

  Routes:
    GET  /login              — Login page ("Sign in with Google")
    GET  /auth/:provider     — Ueberauth redirects to Google
    GET  /auth/:provider/callback — OAuth callback, upsert user, create session
    DELETE /logout           — Destroy session, clear cookie
    GET  /auth/me            — Return current user as JSON
  """
  use CrucibleWeb, :controller

  plug Ueberauth when action in [:request, :callback]

  alias Crucible.Auth

  @sid_cookie "sid"

  # GET /login
  def new(conn, _params) do
    error = conn.query_params["auth_error"]
    render(conn, :login, error: error, layout: {CrucibleWeb.Layouts, :bare})
  end

  # GET /auth/:provider — Ueberauth handles the redirect
  def request(conn, _params), do: conn

  # GET /auth/:provider/callback — success
  def callback(%Plug.Conn{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    email = auth.info.email
    allowed_domain = get_allowed_domain()

    case validate_domain(email, allowed_domain) do
      :ok ->
        profile = %{
          sub: auth.uid,
          email: email,
          name: auth.info.name || "",
          picture_url: safe_picture_url(auth.info.image)
        }

        user = Auth.upsert_oauth_user(profile)
        {sid, _expires} = Auth.create_session(user.id)
        is_prod = Application.get_env(:crucible, :config_env) == :prod

        :telemetry.execute(
          [:crucible, :session, :login],
          %{count: 1},
          %{ip: to_string(:inet.ntoa(conn.remote_ip)), email: email}
        )

        conn
        |> put_resp_cookie(@sid_cookie, sid,
          path: "/",
          http_only: true,
          same_site: "Lax",
          secure: is_prod,
          max_age: Auth.session_ttl_seconds()
        )
        |> redirect(to: "/")

      {:error, reason} ->
        :telemetry.execute(
          [:crucible, :auth, :failure],
          %{count: 1},
          %{ip: to_string(:inet.ntoa(conn.remote_ip)), path: "/auth/callback", reason: reason}
        )

        redirect(conn, to: "/login?auth_error=#{reason}")
    end
  end

  # GET /auth/:provider/callback — failure
  def callback(%Plug.Conn{assigns: %{ueberauth_failure: _failure}} = conn, _params) do
    redirect(conn, to: "/login?auth_error=auth_failed")
  end

  # DELETE /logout
  def delete(conn, _params) do
    conn = fetch_cookies(conn)

    case conn.cookies[@sid_cookie] do
      nil -> :ok
      sid -> Auth.destroy_session(sid)
    end

    :telemetry.execute(
      [:crucible, :session, :logout],
      %{count: 1},
      %{ip: to_string(:inet.ntoa(conn.remote_ip))}
    )

    conn
    |> delete_resp_cookie(@sid_cookie, path: "/")
    |> clear_session()
    |> redirect(to: "/login")
  end

  # GET /auth/me
  def me(conn, _params) do
    case conn.assigns[:current_user] do
      nil -> conn |> put_status(401) |> json(%{authenticated: false})
      user -> json(conn, %{authenticated: true, user: user})
    end
  end

  # When allowed_domain is nil/empty, any authenticated email passes (default for OSS).
  # Operators lock to a domain via OAUTH_ALLOWED_DOMAIN.
  defp validate_domain(_email, allowed_domain) when allowed_domain in [nil, ""], do: :ok

  defp validate_domain(email, allowed_domain) do
    case String.split(email, "@") do
      [_, ^allowed_domain] -> :ok
      _ -> {:error, :domain_not_allowed}
    end
  end

  defp get_allowed_domain do
    Application.get_env(:crucible, :oauth, [])
    |> Keyword.get(:allowed_domain)
  end

  defp safe_picture_url(nil), do: nil

  defp safe_picture_url(url) do
    case URI.parse(url) do
      %URI{scheme: "https"} -> url
      _ -> nil
    end
  end
end
