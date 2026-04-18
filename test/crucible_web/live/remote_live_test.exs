defmodule CrucibleWeb.RemoteLiveTest do
  use CrucibleWeb.ConnCase
  import Phoenix.LiveViewTest

  setup do
    try do
      :ets.new(:rate_limit, [:duplicate_bag, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  test "renders remote page with header and sections", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/remote")
    assert html =~ "REMOTE_LAUNCHER"
    # The form (START_FORM, LAUNCH_SESSION) only renders when no session is running.
    # If a real remote session is active, SESSION_ACTIVE and TERMINATE_SESSION show instead.
    assert html =~ "START_FORM" or html =~ "SESSION_ACTIVE"
    assert html =~ "LAUNCH_SESSION" or html =~ "TERMINATE_SESSION"
  end
end
