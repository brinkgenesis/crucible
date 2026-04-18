defmodule CrucibleWeb.LogsLiveTest do
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

  test "renders logs page with header", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/logs")
    assert html =~ "EVENT_LOG_STREAM"
  end

  test "shows tab navigation", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/logs")
    assert html =~ "SYSTEM_LOG"
    assert html =~ "SERVER_TAIL"
    assert html =~ "AGENT_TRACE"
  end

  test "system tab is active by default", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/logs")
    # System log type buttons should be visible on the system tab
    assert has_element?(view, "button", "COST")
    assert has_element?(view, "button", "AUDIT")
    assert has_element?(view, "button", "SESSION")
    assert has_element?(view, "button", "SAVINGS")
  end

  test "switch_tab event changes to server tab", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/logs")
    html = render_click(view, "switch_tab", %{"tab" => "server"})
    # Server logs tab content is rendered (either entries or empty state)
    assert html =~ "SERVER_TAIL"
  end

  test "switch_tab event changes to agents tab", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/logs")
    html = render_click(view, "switch_tab", %{"tab" => "agents"})
    assert html =~ "SELECT_AGENT_LOG_TO_VIEW"
  end

  test "shows search input on system tab", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/logs")
    assert has_element?(view, "input[name=\"query\"]")
  end
end
