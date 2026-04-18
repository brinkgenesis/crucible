defmodule CrucibleWeb.CostLiveTest do
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

  test "renders cost page with header", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/cost")
    assert html =~ "TOKEN_ANALYTICS"
  end

  test "shows stat cards for token metrics", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/cost")
    assert html =~ "TOTAL_TOKENS"
    assert html =~ "INPUT_TOKENS"
    assert html =~ "OUTPUT_TOKENS"
    assert html =~ "CACHE_HIT_RATE"
  end

  test "shows daily token usage section", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/cost")
    assert html =~ "DAILY_"
    assert html =~ "TOKEN_USAGE"
  end

  test "shows model breakdown section", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/cost")
    assert html =~ "Model Breakdown" or html =~ "MODEL_BREAKDOWN"
  end

  test "toggle_view event switches between tokens and dollars", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/cost")
    # Default view_mode is "tokens", switch to "dollars"
    html = render_click(view, "toggle_view", %{"mode" => "dollars"})
    assert html =~ "DAILY_"
    assert html =~ "SPEND"

    # Switch back to tokens
    html = render_click(view, "toggle_view", %{"mode" => "tokens"})
    assert html =~ "TOKEN_USAGE"
  end

  test "shows sessions section", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/cost")
    assert html =~ "SESSION_ANALYTICS"
    assert html =~ "PROJECT"
    assert html =~ "TURNS"
  end

  test "renders transcript-derived model usage", %{conn: conn} do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cost_live_usage_#{System.unique_integer([:positive])}")

    projects_root = Path.join(tmp_dir, "projects")
    project_dir = Path.join(projects_root, "-Users-helios-infra")
    File.mkdir_p!(project_dir)

    today = Date.utc_today() |> Date.to_iso8601()

    File.write!(
      Path.join(project_dir, "cost-live-session.jsonl"),
      Jason.encode!(%{
        "type" => "assistant",
        "timestamp" => "#{today}T10:00:00Z",
        "message" => %{
          "role" => "assistant",
          "model" => "claude-sonnet-4-6",
          "usage" => %{
            "input_tokens" => 100,
            "output_tokens" => 25,
            "cache_creation_input_tokens" => 30,
            "cache_read_input_tokens" => 40
          }
        }
      }) <> "\n"
    )

    old_env = Application.get_env(:crucible, :llm_usage_reader)

    Application.put_env(
      :crucible,
      :llm_usage_reader,
      projects_root: projects_root,
      infra_home: tmp_dir,
      cache: false,
      min_file_size: 0
    )

    on_exit(fn ->
      if old_env == nil do
        Application.delete_env(:crucible, :llm_usage_reader)
      else
        Application.put_env(:crucible, :llm_usage_reader, old_env)
      end

      File.rm_rf!(tmp_dir)
    end)

    {:ok, _view, html} = conn |> authenticate() |> live("/cost")

    assert html =~ "claude-sonnet-4-6"
    assert html =~ "155"
    assert html =~ "cost-liv"
  end

  test "uses high-contrast chart colors for dark mode", %{conn: conn} do
    {:ok, view, html} = conn |> authenticate() |> live("/cost")

    assert html =~ "#00eefc"

    html = render_click(view, "toggle_view", %{"mode" => "dollars"})
    assert html =~ "#ffa44c"
  end

  @tag :skip
  test "renders context saved metrics from memory savings logs", %{conn: conn} do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cost_live_savings_#{System.unique_integer([:positive])}")

    logs_dir = Path.join([tmp_dir, "global", ".claude-flow", "logs"])
    File.mkdir_p!(logs_dir)

    File.write!(
      Path.join(logs_dir, "memory-savings.jsonl"),
      Jason.encode!(%{
        "timestamp" => "2026-02-15T10:00:00Z",
        "session" => "session-a",
        "project" => "infra",
        "operation" => "context",
        "method" => "memory",
        "notesReturned" => 3,
        "compactTokens" => 600,
        "naiveTokens" => 900,
        "savedTokens" => 300,
        "savedRatio" => 0.3333
      }) <> "\n"
    )

    old_env = Application.get_env(:crucible, :savings_reader)

    Application.put_env(
      :crucible,
      :savings_reader,
      log_dirs: [logs_dir],
      cache: false
    )

    on_exit(fn ->
      if old_env == nil do
        Application.delete_env(:crucible, :savings_reader)
      else
        Application.put_env(:crucible, :savings_reader, old_env)
      end

      File.rm_rf!(tmp_dir)
    end)

    {:ok, _view, html} = conn |> authenticate() |> live("/cost")

    assert html =~ "CONTEXT_SAVED"
    assert html =~ "33.3%"
    assert html =~ "300 TOKENS SAVED"
    assert html =~ "Token Efficiency"
  end
end
