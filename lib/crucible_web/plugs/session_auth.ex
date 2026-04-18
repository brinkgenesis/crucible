defmodule CrucibleWeb.Plugs.SessionAuth do
  @moduledoc """
  Authenticates browser requests via the shared "sid" cookie.

  Reads the plain "sid" cookie (a raw UUID set by either the TS dashboard
  or this app), looks up the session in PostgreSQL, and assigns :current_user.

  When dashboard_auth is disabled (dev mode), auto-creates a dev user
  and session for zero-friction development.
  """
  import Plug.Conn
  alias Crucible.Auth

  @behaviour Plug
  @sid_cookie "sid"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_cookies(conn)

    if dashboard_auth_enabled?() do
      authenticate(conn)
    else
      dev_mode_auth(conn)
    end
  end

  defp authenticate(conn) do
    case conn.cookies[@sid_cookie] do
      nil ->
        assign(conn, :current_user, nil)

      sid ->
        case Auth.lookup_session(sid) do
          nil ->
            conn
            |> delete_resp_cookie(@sid_cookie, path: "/")
            |> assign(:current_user, nil)

          user ->
            assign(conn, :current_user, user)
        end
    end
  end

  defp dev_mode_auth(conn) do
    case conn.cookies[@sid_cookie] do
      nil ->
        create_dev_session(conn)

      sid ->
        case Auth.lookup_session(sid) do
          nil -> create_dev_session(conn)
          user -> assign(conn, :current_user, user)
        end
    end
  end

  defp create_dev_session(conn) do
    user = Auth.ensure_dev_user()
    {sid, _expires} = Auth.create_session(user.id)
    is_prod = Application.get_env(:crucible, :config_env) == :prod

    conn
    |> put_resp_cookie(@sid_cookie, sid,
      path: "/",
      http_only: true,
      same_site: "Lax",
      secure: is_prod,
      max_age: Auth.session_ttl_seconds()
    )
    |> assign(:current_user, %{
      id: user.id,
      email: user.email,
      name: user.name,
      picture_url: user.picture_url,
      role: user.role
    })
  end

  defp dashboard_auth_enabled? do
    Application.get_env(:crucible, :dashboard_auth, false)
  end
end
