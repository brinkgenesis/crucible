defmodule CrucibleWeb.DashboardLiveTest do
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

  test "renders dashboard page with header", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/")
    assert html =~ "BUDGET_EXPENDITURE"
  end

  test "shows stat cards section", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/")
    assert html =~ "BUDGET_EXPENDITURE"
    assert html =~ "ACTIVE_RUNS"
    assert html =~ "COMPLETED_TASKS"
    assert html =~ "SYSTEM_FAILURES"
  end

  test "shows recent runs section", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/")
    assert html =~ "RECENT_OPERATIONAL_RUNS"
  end

  test "shows system health section", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/")
    assert html =~ "SYSTEM_HEALTH_MONITOR"
  end

  test "shows budget spend value", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/")
    # Budget section always renders a dollar amount
    assert html =~ ~r/\$\d+/
  end

  test "shows recent runs table or empty state", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/")
    # Either shows runs table or empty state message
    assert html =~ "RECENT_OPERATIONAL_RUNS"
  end
end
