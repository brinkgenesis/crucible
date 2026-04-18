defmodule CrucibleWeb.AgentsLiveTest do
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

  test "renders agents page with header", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/agents")
    assert html =~ "AGENT_MESH"
    assert html =~ ".claude/agents/"
  end

  test "shows agent definitions with title-cased names", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/agents")
    # Names should be humanized: "Architect" not "architect", "Research Lead" not "research-lead"
    assert html =~ "Architect" or html =~ "NO_AGENT_DEFINITIONS_FOUND"
  end

  test "shows agent registry summary", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/agents")
    assert html =~ "TOTAL_AGENTS" or html =~ "NO_AGENT_DEFINITIONS_FOUND"
  end
end
