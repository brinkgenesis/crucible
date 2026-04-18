defmodule CrucibleWeb.ControlLiveTest do
  use CrucibleWeb.ConnCase
  import Phoenix.LiveViewTest

  test "renders control page with spawn button", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/control")
    html = render(view)
    assert html =~ "SESSION_CONTROL"
    assert html =~ "open_spawn_modal"
  end

  test "opens spawn modal with model and codebase picker", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/control")
    html = view |> element(~s([phx-click="open_spawn_modal"])) |> render_click()
    assert html =~ "SPAWN_PARAM"
    assert html =~ "MODEL_SELECTOR"
  end

  test "closes spawn modal on close click", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/control")
    view |> element(~s([phx-click="open_spawn_modal"])) |> render_click()
    html = render_click(view, "close_spawn_modal")
    refute html =~ "SPAWN_PARAM"
  end

  test "spawn modal shows browse folders button", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/control")
    view |> element(~s([phx-click="open_spawn_modal"])) |> render_click()
    html = render(view)
    assert html =~ "BROWSE_FOLDERS"
  end

  test "browse folders opens directory browser", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/control")
    view |> element(~s([phx-click="open_spawn_modal"])) |> render_click()
    html = view |> element(~s([phx-click="open_browser"])) |> render_click()
    assert html =~ "SELECT_PATH"
    assert html =~ "phx-click=\"browse_up\""
    assert html =~ "phx-click=\"browse_back\""
  end
end
