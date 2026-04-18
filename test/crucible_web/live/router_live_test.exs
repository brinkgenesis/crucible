defmodule CrucibleWeb.RouterLiveTest do
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

  test "renders router page with header and routing sections", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/router")
    # Use render/1 to get connected-state HTML (loading skeleton hidden, real content shown)
    html = render(view)
    assert html =~ "MODEL_ROUTER"
    assert html =~ "Routing Table"
    assert html =~ "Circuit Breakers"
    # Should show models from native registry
    assert html =~ "claude-opus-4-6"
    assert html =~ "anthropic"
  end
end
