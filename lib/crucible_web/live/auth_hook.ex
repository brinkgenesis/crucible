defmodule CrucibleWeb.Live.AuthHook do
  @moduledoc """
  LiveView on_mount hook that verifies dashboard authentication via DB session.

  Reads the "_sid" value from the Phoenix session (copied there by
  CopySidToSession plug), looks up the user in PostgreSQL, and
  assigns :current_user. Redirects to /login if no valid session.

  When `dashboard_auth` config is false (default in dev), auto-assigns dev user.
  """
  import Phoenix.LiveView
  import Phoenix.Component
  alias Crucible.Auth

  def on_mount(:default, _params, session, socket) do
    if dashboard_auth_enabled?() do
      case session["_sid"] do
        nil ->
          {:halt, redirect(socket, to: "/login")}

        sid ->
          case Auth.lookup_session(sid) do
            nil ->
              {:halt, redirect(socket, to: "/login")}

            user ->
              {:cont,
               socket
               |> assign(:current_user, user)
               |> assign(:authenticated, true)}
          end
      end
    else
      # Dev mode — create a dev user for LiveView assigns
      user = Auth.ensure_dev_user()

      {:cont,
       socket
       |> assign(:current_user, %{
         id: user.id,
         email: user.email,
         name: user.name,
         picture_url: user.picture_url,
         role: user.role
       })
       |> assign(:authenticated, true)}
    end
  end

  defp dashboard_auth_enabled? do
    Application.get_env(:crucible, :dashboard_auth, false)
  end
end
