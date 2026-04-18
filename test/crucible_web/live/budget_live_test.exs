defmodule CrucibleWeb.BudgetLiveTest do
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

  test "renders budget page with header", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/budget")
    assert html =~ "BUDGET_ANALYTICS"
  end

  test "shows spend information", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/budget")
    # Budget gauge always renders a dollar amount and limit text
    assert html =~ ~r/\$\d+/
    assert html =~ "LIMIT"
  end

  test "shows spend by model section", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/budget")
    assert html =~ "SPEND_BY_MODEL"
  end

  test "shows recent cost events section", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/budget")
    assert html =~ "COST_EVENT_LOG"
  end

  test "shows events section with table or empty state", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/budget")
    # Either shows events table or empty state
    assert html =~ "COST_EVENT_LOG"
  end
end
