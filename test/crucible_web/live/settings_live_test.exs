defmodule CrucibleWeb.SettingsLiveTest do
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

  test "renders settings page with all sections", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/settings")
    # Header
    assert html =~ "SYSTEM_CONFIGURATION"
    # Service Health section
    assert html =~ "Service Health"
    assert html =~ "API_SERVER"
    # GenServer status entries (uppercased via String.upcase)
    assert html =~ "BUDGETTRACKER"
    assert html =~ "COSTEVENTREADER"
    assert html =~ "ORCHESTRATOR"
    assert html =~ "RESULTSTORE"
    assert html =~ "WORKFLOWSTORE"
    assert html =~ "SELFIMPROVEMENT"
    # Budget Limits section
    assert html =~ "Budget Limits"
    assert html =~ "DAILY_LIMIT"
    assert html =~ "PER_AGENT"
    assert html =~ "PER_TASK"
    # Environment section
    assert html =~ "Environment"
    # System Info section
    assert html =~ "System Info"
    assert html =~ "ELIXIR"
    assert html =~ "OTP"
    assert html =~ "PHOENIX"
  end
end
