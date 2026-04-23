defmodule CrucibleWeb.ConfigLiveTest do
  use CrucibleWeb.ConnCase
  import Phoenix.LiveViewTest

  setup do
    previous_orchestrator = Application.get_env(:crucible, :orchestrator, [])

    try do
      :ets.new(:rate_limit, [:duplicate_bag, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    on_exit(fn ->
      Application.put_env(:crucible, :orchestrator, previous_orchestrator)
    end)

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

  test "sensitive env values are masked and blank submit preserves stored value", %{conn: conn} do
    repo_root =
      Path.join(System.tmp_dir!(), "crucible-config-live-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(repo_root, ".claude-flow"))
    File.write!(Path.join(repo_root, ".env"), "DATABASE_URL=ecto://masked-secret\n")
    File.write!(Path.join(repo_root, ".claude-flow/config.yaml"), "router: {}\n")

    Application.put_env(:crucible, :orchestrator, repo_root: repo_root)

    on_exit(fn ->
      File.rm_rf(repo_root)
    end)

    {:ok, view, _html} = conn |> authenticate() |> live("/config")

    html = render_click(view, "switch_tab", %{"tab" => "environment"})
    refute html =~ "ecto://masked-secret"

    view
    |> form("#env-form-database-url", %{"env" => %{"key" => "DATABASE_URL", "value" => ""}})
    |> render_submit()

    assert File.read!(Path.join(repo_root, ".env")) =~ "DATABASE_URL=ecto://masked-secret"
  end
end
