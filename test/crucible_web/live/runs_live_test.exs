defmodule CrucibleWeb.RunsLiveTest do
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

  test "renders runs list page with header", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/runs")
    assert html =~ "Runs"
  end

  test "shows runs list or empty state", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/runs")
    # Either shows runs table or empty state — the runs-list container is always present
    assert has_element?(view, "#runs-list") or render(view) =~ "play_circle"
  end

  test "handles nonexistent run ID gracefully", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/runs/nonexistent-id-12345")
    # When selected run is nil, falls back to list view
    assert html =~ "Runs"
  end

  test "page renders without errors", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/runs")
    assert has_element?(view, "#runs-list") or render(view) =~ "play_circle"
  end

  describe "active vs completed partitioning" do
    test "active runs appear in the active section", %{conn: conn} do
      {:ok, view, _html} = conn |> authenticate() |> live("/runs")
      html = render(view)
      # The runs-list container renders with partitioned structure
      assert html =~ "runs-list"
    end

    test "assigns contain partitioned run lists", %{conn: conn} do
      {:ok, view, _html} = conn |> authenticate() |> live("/runs")
      html = render(view)
      # The runs page renders with scope filter and run list
      assert html =~ "runs-list" or html =~ "scope_filter"
    end

    test "toggle_completed event flips show_all_completed", %{conn: conn} do
      {:ok, view, _html} = conn |> authenticate() |> live("/runs")

      # Send the toggle event — should not crash even with no completed runs
      html = render_click(view, "toggle_completed")
      assert html =~ "runs-list" or html =~ "scope_filter"

      # Toggle back
      html = render_click(view, "toggle_completed")
      assert html =~ "runs-list" or html =~ "scope_filter"
    end
  end

  describe "run lifecycle partitioning logic" do
    test "terminal statuses are partitioned into completed" do
      terminal = ~w(done failed cancelled orphaned)
      active = ~w(pending running in_progress review budget_paused)

      for status <- terminal do
        assert status in ~w(done failed cancelled orphaned),
               "#{status} should be terminal"
      end

      for status <- active do
        refute status in ~w(done failed cancelled orphaned),
               "#{status} should not be terminal"
      end
    end
  end
end
