defmodule CrucibleWeb.CodebaseLiveTest do
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

  test "renders codebase page with header, stats, and table", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/codebase")
    assert html =~ "CODEBASE_INTELLIGENCE"
    assert html =~ "MODULES"
    assert html =~ "EDGES"
    assert html =~ "LIST"
    assert html =~ "GRAPH"
    assert html =~ "modules"
  end

  test "shows module table headers in list view", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/codebase")
    assert html =~ "Module"
    assert html =~ "Deps"
    assert html =~ "Symbols"
    assert html =~ "Exported"
  end
end
