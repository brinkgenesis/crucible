defmodule CrucibleWeb.ConfigLiveTest do
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

  test "renders config page with header and tabs", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/config")
    assert html =~ "CONFIGURATION"
    assert html =~ "CLAUDE_FLOW"
    assert html =~ "ENVIRONMENT"
    assert html =~ "BUDGET_LIMITS"
  end

  test "switch_tab event shows environment tab", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/config")
    html = render_click(view, "switch_tab", %{"tab" => "environment"})
    assert html =~ "ENVIRONMENT"
  end

  test "switch_tab event shows budget tab with form fields", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/config")
    html = render_click(view, "switch_tab", %{"tab" => "budget"})
    assert html =~ "BUDGET LIMITS"
    assert html =~ "Daily Limit"
    assert html =~ "Per Agent"
    assert html =~ "Per Task"
    assert html =~ "SAVE BUDGET"
  end
end
