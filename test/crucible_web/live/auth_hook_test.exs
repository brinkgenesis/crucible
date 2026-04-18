defmodule CrucibleWeb.Live.AuthHookTest do
  use Crucible.DataCase, async: true

  alias CrucibleWeb.Live.AuthHook
  alias Crucible.Auth

  defp socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}}, assigns),
      redirected: nil
    }
  end

  describe "on_mount/4 with dashboard_auth disabled" do
    setup do
      prev = Application.get_env(:crucible, :dashboard_auth)
      Application.put_env(:crucible, :dashboard_auth, false)
      on_exit(fn -> Application.put_env(:crucible, :dashboard_auth, prev) end)
      :ok
    end

    test "allows mount with dev user" do
      assert {:cont, socket} = AuthHook.on_mount(:default, %{}, %{}, socket())
      assert socket.assigns.authenticated == true
      assert socket.assigns.current_user.email == "dev@localhost"
    end
  end

  describe "on_mount/4 with dashboard_auth enabled" do
    setup do
      prev = Application.get_env(:crucible, :dashboard_auth)
      Application.put_env(:crucible, :dashboard_auth, true)
      on_exit(fn -> Application.put_env(:crucible, :dashboard_auth, prev) end)
      :ok
    end

    test "allows mount with valid session" do
      user = Auth.ensure_dev_user()
      {sid, _expires} = Auth.create_session(user.id)

      session = %{"_sid" => sid}
      assert {:cont, socket} = AuthHook.on_mount(:default, %{}, session, socket())
      assert socket.assigns.authenticated == true
      assert socket.assigns.current_user.id == user.id
    end

    test "redirects to /login without session token" do
      assert {:halt, socket} = AuthHook.on_mount(:default, %{}, %{}, socket())
      assert {:redirect, %{to: "/login"}} = socket.redirected
    end

    test "redirects with invalid session id" do
      session = %{"_sid" => Ecto.UUID.generate()}
      assert {:halt, socket} = AuthHook.on_mount(:default, %{}, session, socket())
      assert {:redirect, %{to: "/login"}} = socket.redirected
    end
  end
end
