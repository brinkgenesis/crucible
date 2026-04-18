defmodule CrucibleWeb.TracesLiveTest do
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

  test "renders traces list page with header", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/traces")
    assert html =~ "TRACE_ANALYTICS"
  end

  test "shows time window filter buttons", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/traces")
    assert html =~ "24h"
    assert html =~ "7d"
    assert html =~ "30d"
  end

  test "shows summary cards", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/traces")
    assert html =~ "TOTAL_RUNS"
    assert html =~ "AVG_DURATION"
    assert html =~ "TOTAL_COST"
    assert html =~ "SUCCESS_RATE"
  end

  test "set_window event updates the time filter", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/traces")
    html = render_click(view, "set_window", %{"window" => "24h"})
    assert html =~ "TRACE_ANALYTICS"
    assert html =~ "24h"
  end

  test "set_window can switch back to 7d from 30d", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/traces?window=30d")

    render_click(view, "set_window", %{"window" => "7d"})
    assert_patch(view, "/traces")

    html = render(view)
    assert html =~ "7d"
  end

  test "handles trace detail route for nonexistent run", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/traces/nonexistent-run-id")
    # Detail view renders the run_id even if summary is nil
    assert html =~ "nonexistent-run"
  end

  test "shows trace data or empty state", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/traces")
    # Either traces are loaded from disk or the empty state is shown
    assert html =~ "TOTAL_RUNS"
  end

  test "detail view shows Agents tab button", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticate() |> live("/traces/test-run-id")
    assert html =~ "AGENTS"
  end

  test "switch_tab to agents renders agents section", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/traces/test-run-id")
    html = render_click(view, "switch_tab", %{"tab" => "agents"})
    # Should show the agents view (empty state or agent cards)
    assert html =~ "agent" or html =~ "Agent" or html =~ "Session Logs"
  end

  test "toggle_session_log event is handled without crash", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/traces/test-run-id")
    # Switch to agents tab first
    render_click(view, "switch_tab", %{"tab" => "agents"})
    # Toggle a nonexistent phase log - should not crash
    html = render_click(view, "toggle_session_log", %{"phase" => "phase-0"})
    assert html =~ "Agents" or html =~ "agent"
  end

  test "timeline shows staggered phase offsets from actual timestamps", %{conn: conn} do
    tmp_dir =
      Path.join(System.tmp_dir!(), "trace_timeline_#{System.unique_integer([:positive])}")

    traces_dir = Path.join([tmp_dir, ".claude-flow", "logs", "traces"])
    File.mkdir_p!(traces_dir)

    run_id = "trace-timeline-run"

    events = [
      %{
        "timestamp" => "2026-03-14T10:00:00Z",
        "runId" => run_id,
        "phaseId" => "phase-1",
        "eventType" => "phase_start",
        "detail" => "Sprint",
        "metadata" => %{}
      },
      %{
        "timestamp" => "2026-03-14T10:05:00Z",
        "runId" => run_id,
        "phaseId" => "phase-1",
        "eventType" => "phase_end",
        "detail" => "Sprint",
        "metadata" => %{"status" => "done"}
      },
      %{
        "timestamp" => "2026-03-14T10:07:00Z",
        "runId" => run_id,
        "phaseId" => "phase-2",
        "eventType" => "phase_start",
        "detail" => "Review",
        "metadata" => %{}
      },
      %{
        "timestamp" => "2026-03-14T10:10:00Z",
        "runId" => run_id,
        "phaseId" => "phase-2",
        "eventType" => "phase_end",
        "detail" => "Review",
        "metadata" => %{"status" => "done"}
      }
    ]

    File.write!(
      Path.join(traces_dir, "#{run_id}.jsonl"),
      Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n"
    )

    old_env = Application.get_env(:crucible, :orchestrator)

    Application.put_env(
      :crucible,
      :orchestrator,
      Keyword.merge(old_env || [], repo_root: tmp_dir)
    )

    on_exit(fn ->
      if old_env == nil do
        Application.delete_env(:crucible, :orchestrator)
      else
        Application.put_env(:crucible, :orchestrator, old_env)
      end

      File.rm_rf!(tmp_dir)
    end)

    {:ok, _view, html} = conn |> authenticate() |> live("/traces/#{run_id}")

    assert html =~ "start +0s"
    # Phase 2 starts at +5m (rebased: idle gap between 10:05→10:07 collapsed)
    assert html =~ "start +5m 0s"
  end

  @tag :skip

  test "trace list shows duration and tokens while hiding junk file traces", %{conn: conn} do
    tmp_dir =
      Path.join(System.tmp_dir!(), "trace_list_#{System.unique_integer([:positive])}")

    traces_dir = Path.join([tmp_dir, ".claude-flow", "logs", "traces"])
    File.mkdir_p!(traces_dir)

    File.write!(
      Path.join(traces_dir, "real-run.jsonl"),
      Enum.map_join(
        [
          %{
            "timestamp" => "2026-03-14T10:00:00Z",
            "runId" => "real-run",
            "workflowName" => "coding-sprint",
            "eventType" => "phase_start",
            "phaseId" => "phase-0",
            "detail" => "Sprint"
          },
          %{
            "timestamp" => "2026-03-14T10:00:30Z",
            "runId" => "real-run",
            "eventType" => "token_efficiency",
            "phaseId" => "phase-0",
            "metadata" => %{
              "inputTokens" => 200,
              "outputTokens" => 100,
              "result" => "done",
              "duration_ms" => 30_000
            }
          },
          %{
            "timestamp" => "2026-03-14T10:01:00Z",
            "runId" => "real-run",
            "eventType" => "phase_end",
            "phaseId" => "phase-0",
            "metadata" => %{"status" => "done"}
          }
        ],
        "\n",
        &Jason.encode!/1
      ) <> "\n"
    )

    File.write!(
      Path.join(traces_dir, "test-run-123.jsonl"),
      Jason.encode!(%{
        "timestamp" => "2026-03-14T10:00:00Z",
        "runId" => "test-run-123",
        "eventType" => "tool_call",
        "tool" => "TaskCreate",
        "detail" => "Backend implementation - Test task"
      }) <> "\n"
    )

    File.write!(
      Path.join(traces_dir, "unscoped.jsonl"),
      Jason.encode!(%{
        "timestamp" => "2026-03-14T10:00:00Z",
        "eventType" => "tool_call",
        "detail" => "junk"
      }) <> "\n"
    )

    old_env = Application.get_env(:crucible, :orchestrator)

    Application.put_env(
      :crucible,
      :orchestrator,
      Keyword.merge(old_env || [], repo_root: tmp_dir)
    )

    on_exit(fn ->
      if old_env == nil do
        Application.delete_env(:crucible, :orchestrator)
      else
        Application.put_env(:crucible, :orchestrator, old_env)
      end

      File.rm_rf!(tmp_dir)
    end)

    {:ok, _view, html} = conn |> authenticate() |> live("/traces?window=30d")

    assert html =~ "TOTAL_RUNS"
    assert html =~ "300"
    assert html =~ "1m 0s"
    assert html =~ "real-run"
    refute html =~ "test-run-123"
    refute html =~ "unscoped"
  end

  @tag :skip

  test "trace list falls back to transcript tokens and hides card-deleted orphaned runs", %{
    conn: conn
  } do
    tmp_dir =
      Path.join(System.tmp_dir!(), "trace_transcript_#{System.unique_integer([:positive])}")

    traces_dir = Path.join([tmp_dir, ".claude-flow", "logs", "traces"])
    File.mkdir_p!(traces_dir)

    projects_root = Path.join(tmp_dir, "projects")
    project_slug = "-tmp-trace-transcript"
    project_dir = Path.join(projects_root, project_slug)
    File.mkdir_p!(project_dir)

    session_id = "11111111-1111-1111-1111-111111111111"

    File.write!(
      Path.join(project_dir, "#{session_id}.jsonl"),
      Enum.map_join(
        [
          %{
            "timestamp" => "2026-03-14T10:00:10Z",
            "message" => %{
              "usage" => %{
                "input_tokens" => 300,
                "output_tokens" => 120
              }
            }
          }
        ],
        "\n",
        &Jason.encode!/1
      ) <> "\n"
    )

    File.write!(
      Path.join(traces_dir, "real-transcript-run.jsonl"),
      Enum.map_join(
        [
          %{
            "timestamp" => "2026-03-14T10:00:00Z",
            "runId" => "real-transcript-run",
            "workflowName" => "coding-sprint",
            "eventType" => "tool_call",
            "tool" => "Bash",
            "sessionId" => session_id,
            "detail" => "run"
          },
          %{
            "timestamp" => "2026-03-14T10:01:00Z",
            "runId" => "real-transcript-run",
            "eventType" => "phase_end",
            "phaseId" => "phase-0",
            "metadata" => %{"status" => "done"}
          }
        ],
        "\n",
        &Jason.encode!/1
      ) <> "\n"
    )

    File.write!(
      Path.join(traces_dir, "deleted-orphan-run.jsonl"),
      Enum.map_join(
        [
          %{
            "timestamp" => "2026-03-14T10:00:00Z",
            "runId" => "deleted-orphan-run",
            "workflowName" => "coding-sprint",
            "eventType" => "checkpoint",
            "detail" => "Run orphaned because card was deleted",
            "metadata" => %{"stage" => "run_orphaned", "cardId" => nil}
          },
          %{
            "timestamp" => "2026-03-14T10:00:02Z",
            "runId" => "deleted-orphan-run",
            "eventType" => "checkpoint",
            "detail" => "Run status transitioned: running -> orphaned",
            "metadata" => %{"to" => "orphaned"}
          }
        ],
        "\n",
        &Jason.encode!/1
      ) <> "\n"
    )

    old_env = Application.get_env(:crucible, :orchestrator)
    old_llm_env = Application.get_env(:crucible, :llm_usage_reader)

    Application.put_env(
      :crucible,
      :orchestrator,
      Keyword.merge(old_env || [], repo_root: tmp_dir)
    )

    Application.put_env(
      :crucible,
      :llm_usage_reader,
      Keyword.merge(old_llm_env || [],
        projects_root: projects_root,
        cache: false,
        min_file_size: 0
      )
    )

    on_exit(fn ->
      if old_env == nil do
        Application.delete_env(:crucible, :orchestrator)
      else
        Application.put_env(:crucible, :orchestrator, old_env)
      end

      if old_llm_env == nil do
        Application.delete_env(:crucible, :llm_usage_reader)
      else
        Application.put_env(:crucible, :llm_usage_reader, old_llm_env)
      end

      File.rm_rf!(tmp_dir)
    end)

    {:ok, _view, html} = conn |> authenticate() |> live("/traces?window=30d")

    assert html =~ "real-transcript-run"
    assert html =~ "420"
    refute html =~ "deleted-orphan-run"
  end

  # ---------------------------------------------------------------------------
  # sort event
  # ---------------------------------------------------------------------------

  test "sort event changes sort_by assign", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/traces")
    html = render_click(view, "sort", %{"by" => "cost"})
    # After sorting by cost the column header should still render
    assert html =~ "TOTAL_COST"
  end

  test "sort event with invalid field is ignored", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/traces")
    # Should not crash; sort_by stays at default "time"
    html = render_click(view, "sort", %{"by" => "malicious_field"})
    assert html =~ "TRACE_ANALYTICS"
  end

  # ---------------------------------------------------------------------------
  # filter_events
  # ---------------------------------------------------------------------------

  test "filter_events updates event filter on detail view", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/traces/test-run-id")
    render_click(view, "switch_tab", %{"tab" => "events"})
    html = render_change(view, "filter_events", %{"q" => "phase_start"})
    # Filter input should reflect the query (rendered as value)
    assert html =~ "phase_start"
  end

  # ---------------------------------------------------------------------------
  # page event
  # ---------------------------------------------------------------------------

  test "page event updates the current page", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/traces")
    html = render_click(view, "page", %{"page" => "2"})
    # Should not crash; page renders even if there aren't enough results
    assert html =~ "TRACE_ANALYTICS"
  end

  # ---------------------------------------------------------------------------
  # set_scope_filters
  # ---------------------------------------------------------------------------

  test "set_scope_filters triggers a patch", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/traces")
    render_click(view, "set_scope_filters", %{"client_id" => "test-client"})
    # After patch, page still renders
    html = render(view)
    assert html =~ "TRACE_ANALYTICS"
  end

  # ---------------------------------------------------------------------------
  # Selection: toggle_select, select_all, deselect_all
  # ---------------------------------------------------------------------------

  test "toggle_select adds and removes a run from selection", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/traces")
    # Toggle a run_id — should not crash even if run_id doesn't exist in list
    html = render_click(view, "toggle_select", %{"run_id" => "some-run"})
    assert html =~ "TRACE_ANALYTICS"
    # Toggle again to deselect
    html = render_click(view, "toggle_select", %{"run_id" => "some-run"})
    assert html =~ "TRACE_ANALYTICS"
  end

  test "select_all and deselect_all work without crash", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/traces")
    html = render_click(view, "select_all", %{})
    assert html =~ "TRACE_ANALYTICS"
    html = render_click(view, "deselect_all", %{})
    assert html =~ "TRACE_ANALYTICS"
  end

  # ---------------------------------------------------------------------------
  # delete_selected
  # ---------------------------------------------------------------------------

  test "delete_selected with empty selection does not crash", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/traces")
    html = render_click(view, "delete_selected", %{})
    assert html =~ "TRACE_ANALYTICS"
  end

  # ---------------------------------------------------------------------------
  # Compare view
  # ---------------------------------------------------------------------------

  test "compare view renders without crash for two run IDs", %{conn: conn} do
    {:ok, _view, html} =
      conn |> authenticate() |> live("/traces/compare/left-run-id/right-run-id")

    assert html =~ "left-run-id"
    assert html =~ "right-run-id"
  end

  # ---------------------------------------------------------------------------
  # Detail tab switching across all 7 tabs
  # ---------------------------------------------------------------------------

  test "switch_tab renders all 7 tabs without crash", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/traces/test-run-id")

    for tab <- ~w(timeline tools costs events files tasks agents) do
      html = render_click(view, "switch_tab", %{"tab" => tab})
      assert html =~ "test-run"
    end
  end

  test "switch_tab with invalid tab is ignored", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/traces/test-run-id")
    # Should not crash; detail_tab stays at "timeline"
    html = render_click(view, "switch_tab", %{"tab" => "nonexistent"})
    assert html =~ "test-run"
  end

  # ---------------------------------------------------------------------------
  # Empty states in detail tabs
  # ---------------------------------------------------------------------------

  test "tools tab shows styled empty state", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/traces/test-run-id")
    html = render_click(view, "switch_tab", %{"tab" => "tools"})
    assert html =~ "NO_TOOL_USAGE_RECORDED"
  end

  test "costs tab shows styled empty state", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/traces/test-run-id")
    html = render_click(view, "switch_tab", %{"tab" => "costs"})
    assert html =~ "NO_COST_DATA_AVAILABLE"
  end

  test "files tab shows styled empty state", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/traces/test-run-id")
    html = render_click(view, "switch_tab", %{"tab" => "files"})
    assert html =~ "NO_FILE_CHANGES_TRACKED"
  end

  test "events tab shows styled empty state when no events", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticate() |> live("/traces/test-run-id")
    html = render_click(view, "switch_tab", %{"tab" => "events"})
    assert html =~ "NO_TRACE_EVENTS_RECORDED" or html =~ "NO_EVENTS_MATCH_FILTER"
  end
end
