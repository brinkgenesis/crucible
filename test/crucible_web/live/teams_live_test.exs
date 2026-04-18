defmodule CrucibleWeb.TeamsLiveTest do
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

  test "renders activity page with active sessions only", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/teams")
    assert html =~ "ACTIVITY_MONITOR"
    assert html =~ "ACTIVE_SESSIONS"
  end

  test "renders team detail page for nonexistent team", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/teams/nonexistent-team")
    assert html =~ "ACTIVITY_MONITOR" or html =~ "ACTIVE_SESSIONS"
  end
end
