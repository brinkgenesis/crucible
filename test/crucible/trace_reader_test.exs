defmodule Crucible.TraceReaderTest do
  use ExUnit.Case, async: true

  alias Crucible.TraceReader

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "trace_reader_test_#{:rand.uniform(100_000)}")
    traces_dir = Path.join(tmp_dir, "traces")
    sessions_dir = Path.join(tmp_dir, "sessions")
    runs_dir = Path.join(tmp_dir, "runs")

    File.mkdir_p!(traces_dir)
    File.mkdir_p!(sessions_dir)
    File.mkdir_p!(runs_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{traces_dir: traces_dir, sessions_dir: sessions_dir, runs_dir: runs_dir}
  end

  describe "events_for_run/2" do
    test "reads events from JSONL file", %{traces_dir: traces_dir} do
      events = [
        %{
          "eventType" => "phase_start",
          "runId" => "run-1",
          "timestamp" => "2026-01-01T00:00:00Z"
        },
        %{"eventType" => "tool_call", "runId" => "run-1", "tool" => "Bash", "detail" => "echo hi"}
      ]

      path = Path.join(traces_dir, "run-1.jsonl")
      content = Enum.map_join(events, "\n", &Jason.encode!/1)
      File.write!(path, content)

      result = TraceReader.events_for_run("run-1", traces_dir: traces_dir)
      assert length(result) == 2
      assert hd(result)["eventType"] == "phase_start"
    end

    test "returns empty list for nonexistent run", %{traces_dir: traces_dir} do
      assert TraceReader.events_for_run("nonexistent", traces_dir: traces_dir) == []
    end

    test "respects limit option", %{traces_dir: traces_dir} do
      events =
        for i <- 1..10 do
          Jason.encode!(%{
            "eventType" => "tool_call",
            "runId" => "run-2",
            "detail" => "event-#{i}"
          })
        end

      File.write!(Path.join(traces_dir, "run-2.jsonl"), Enum.join(events, "\n"))

      result = TraceReader.events_for_run("run-2", traces_dir: traces_dir, limit: 3)
      assert length(result) == 3
      # Should return last 3
      assert List.last(result)["detail"] == "event-10"
    end

    test "skips malformed lines", %{traces_dir: traces_dir} do
      content = ~s({"eventType":"ok"}\nnot json\n{"eventType":"also_ok"})
      File.write!(Path.join(traces_dir, "run-3.jsonl"), content)

      result = TraceReader.events_for_run("run-3", traces_dir: traces_dir)
      assert length(result) == 2
    end
  end

  describe "session_log/3" do
    test "reads session log file", %{sessions_dir: sessions_dir} do
      File.write!(Path.join(sessions_dir, "run-1-phase-0.log"), "hello world output")

      assert TraceReader.session_log("run-1", "phase-0", sessions_dir: sessions_dir) ==
               "hello world output"
    end

    test "returns nil for missing log", %{sessions_dir: sessions_dir} do
      assert TraceReader.session_log("run-x", "phase-0", sessions_dir: sessions_dir) == nil
    end
  end

  describe "list_runs/1" do
    test "lists runs from JSONL filenames with duration and token totals", %{
      traces_dir: traces_dir
    } do
      events = [
        %{
          "eventType" => "phase_start",
          "runId" => "run-a",
          "timestamp" => "2026-01-01T00:00:01Z",
          "workflowName" => "test-wf"
        },
        %{
          "eventType" => "token_efficiency",
          "runId" => "run-a",
          "phaseId" => "phase-0",
          "timestamp" => "2026-01-01T00:00:31Z",
          "metadata" => %{"inputTokens" => 200, "outputTokens" => 100, "result" => "done"}
        },
        %{
          "eventType" => "phase_end",
          "runId" => "run-a",
          "timestamp" => "2026-01-01T00:01:00Z",
          "metadata" => %{"status" => "done"}
        }
      ]

      File.write!(
        Path.join(traces_dir, "run-a.jsonl"),
        Enum.map_join(events, "\n", &Jason.encode!/1)
      )

      result = TraceReader.list_runs(traces_dir: traces_dir)
      assert length(result) == 1
      run = hd(result)
      assert run.run_id == "run-a"
      assert run.status == "done"
      assert run.event_count == 3
      assert run.workflow_name == "test-wf"
      assert run.duration_ms == 59_000
      assert run.total_tokens == 300
    end

    test "returns empty list for nonexistent dir" do
      assert TraceReader.list_runs(traces_dir: "/tmp/nonexistent_#{:rand.uniform(100_000)}") == []
    end

    test "ignores junk files and infers terminal status from file events", %{
      traces_dir: traces_dir
    } do
      File.write!(
        Path.join(traces_dir, "run-done.jsonl"),
        Jason.encode!(%{
          "eventType" => "token_efficiency",
          "runId" => "run-done",
          "phaseId" => "phase-0",
          "timestamp" => "2026-01-01T00:01:00Z",
          "metadata" => %{"inputTokens" => 25, "outputTokens" => 10, "result" => "done"}
        }) <> "\n"
      )

      File.write!(
        Path.join(traces_dir, "run-orphan.jsonl"),
        Jason.encode!(%{
          "eventType" => "checkpoint",
          "runId" => "run-orphan",
          "timestamp" => "2026-01-01T00:02:00Z",
          "metadata" => %{"stage" => "run_orphaned", "workflow" => "coding-sprint"}
        }) <> "\n"
      )

      File.write!(
        Path.join(traces_dir, "test-run-123.jsonl"),
        Jason.encode!(%{"eventType" => "tool_call", "runId" => "test-run-123"}) <> "\n"
      )

      File.write!(
        Path.join(traces_dir, "unscoped.jsonl"),
        Jason.encode!(%{"eventType" => "tool_call", "detail" => "junk"}) <> "\n"
      )

      result = TraceReader.list_runs(traces_dir: traces_dir)
      ids = Enum.map(result, & &1.run_id)

      assert "run-done" in ids
      assert "run-orphan" in ids
      refute "test-run-123" in ids
      refute "unscoped" in ids

      assert Enum.find(result, &(&1.run_id == "run-done")).status == "done"
      assert Enum.find(result, &(&1.run_id == "run-orphan")).status == "orphaned"
    end
  end

  describe "run_summary/2" do
    test "computes summary with phases, tools, costs", %{traces_dir: traces_dir} do
      events = [
        %{
          "eventType" => "phase_start",
          "phaseId" => "p1",
          "detail" => "Planning",
          "timestamp" => "2026-01-01T00:00:01Z",
          "agentId" => "a1"
        },
        %{
          "eventType" => "tool_call",
          "tool" => "Read",
          "phaseId" => "p1",
          "timestamp" => "2026-01-01T00:00:02Z"
        },
        %{
          "eventType" => "tool_call",
          "tool" => "Read",
          "phaseId" => "p1",
          "timestamp" => "2026-01-01T00:00:03Z"
        },
        %{
          "eventType" => "tool_call",
          "tool" => "Edit",
          "phaseId" => "p1",
          "timestamp" => "2026-01-01T00:00:04Z"
        },
        %{
          "eventType" => "token_efficiency",
          "phaseId" => "p1",
          "timestamp" => "2026-01-01T00:00:05Z",
          "metadata" => %{
            "inputTokens" => 1000,
            "outputTokens" => 500,
            "costUsd" => 0.05,
            "duration_ms" => 4000
          }
        },
        %{"eventType" => "phase_end", "phaseId" => "p1", "timestamp" => "2026-01-01T00:00:05Z"}
      ]

      File.write!(
        Path.join(traces_dir, "run-summary.jsonl"),
        Enum.map_join(events, "\n", &Jason.encode!/1)
      )

      summary = TraceReader.run_summary("run-summary", traces_dir: traces_dir)
      assert summary.event_count == 6
      assert summary.phase_count == 1
      assert summary.agent_count == 1
      assert length(summary.tools) > 0
      assert {"Read", 2} = Enum.find(summary.tools, fn {tool, _} -> tool == "Read" end)
      assert_in_delta summary.total_cost_usd, 0.05, 0.001
      assert summary.total_input_tokens == 1000
      assert summary.total_output_tokens == 500
    end

    test "returns empty summary for nonexistent run", %{traces_dir: traces_dir} do
      summary = TraceReader.run_summary("nonexistent", traces_dir: traces_dir)
      assert summary.event_count == 0
      assert summary.phase_count == 0
    end
  end

  describe "lifecycle_agents/2" do
    test "reads and filters lifecycle events by run prefix", %{} do
      tmp_dir = Path.join(System.tmp_dir!(), "lifecycle_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)
      lifecycle_path = Path.join(tmp_dir, "agent-lifecycle.jsonl")

      events = [
        %{
          "event" => "teammate_idle",
          "teammate_name" => "coder-backend",
          "team_name" => "coding-sprint-abc12345-0",
          "timestamp" => "2026-01-01T00:01:00Z",
          "session_id" => "s1"
        },
        %{
          "event" => "teammate_idle",
          "teammate_name" => "coder-frontend",
          "team_name" => "coding-sprint-abc12345-0",
          "timestamp" => "2026-01-01T00:02:00Z",
          "session_id" => "s2"
        },
        %{
          "event" => "teammate_idle",
          "teammate_name" => "other-agent",
          "team_name" => "coding-sprint-zzzzz-0",
          "timestamp" => "2026-01-01T00:03:00Z",
          "session_id" => "s3"
        }
      ]

      File.write!(lifecycle_path, Enum.map_join(events, "\n", &Jason.encode!/1))

      result = TraceReader.lifecycle_agents("abc12345xyz", lifecycle_path: lifecycle_path)
      names = Enum.map(result, & &1.name) |> Enum.sort()
      assert names == ["coder-backend", "coder-frontend"]

      on_exit(fn -> File.rm_rf!(tmp_dir) end)
    end

    test "returns empty list for missing lifecycle file" do
      result =
        TraceReader.lifecycle_agents("abc12345",
          lifecycle_path: "/tmp/nonexistent_lifecycle.jsonl"
        )

      assert result == []
    end
  end

  describe "session_logs_for_run/2" do
    test "returns map of phase_id to log content", %{sessions_dir: sessions_dir} do
      File.write!(Path.join(sessions_dir, "run-sl-phase-0.log"), "phase 0 output")
      File.write!(Path.join(sessions_dir, "run-sl-phase-1.log"), "phase 1 output")

      result = TraceReader.session_logs_for_run("run-sl", sessions_dir: sessions_dir)
      assert map_size(result) == 2
      assert result["phase-0"] == "phase 0 output"
      assert result["phase-1"] == "phase 1 output"
    end

    test "returns empty map for run with no session logs", %{sessions_dir: sessions_dir} do
      result = TraceReader.session_logs_for_run("no-such-run", sessions_dir: sessions_dir)
      assert result == %{}
    end
  end

  describe "run_summary agent_details" do
    test "extracts agents from Agent tool_call events", %{traces_dir: traces_dir} do
      events = [
        %{
          "eventType" => "tool_call",
          "tool" => "Agent",
          "detail" => "coder-backend",
          "phaseId" => "p1",
          "timestamp" => "2026-01-01T00:00:01Z"
        },
        %{
          "eventType" => "tool_call",
          "tool" => "Agent",
          "detail" => "coder-frontend",
          "phaseId" => "p1",
          "timestamp" => "2026-01-01T00:00:02Z"
        },
        %{
          "eventType" => "tool_call",
          "tool" => "Bash",
          "detail" => "echo hi",
          "phaseId" => "p1",
          "timestamp" => "2026-01-01T00:00:03Z"
        }
      ]

      File.write!(
        Path.join(traces_dir, "run-agents.jsonl"),
        Enum.map_join(events, "\n", &Jason.encode!/1)
      )

      summary = TraceReader.run_summary("run-agents", traces_dir: traces_dir)
      assert summary.agent_spawn_count == 2
      assert length(summary.agent_details) == 2
      names = Enum.map(summary.agent_details, & &1.name)
      assert "coder-backend" in names
      assert "coder-frontend" in names
    end

    test "extracts agents from phase_start metadata", %{traces_dir: traces_dir} do
      events = [
        %{
          "eventType" => "phase_start",
          "phaseId" => "p1",
          "detail" => "Sprint",
          "timestamp" => "2026-01-01T00:00:01Z",
          "metadata" => %{"agents" => ["coder-a", "coder-b"], "phaseType" => "team"}
        },
        %{"eventType" => "phase_end", "phaseId" => "p1", "timestamp" => "2026-01-01T00:00:05Z"}
      ]

      File.write!(
        Path.join(traces_dir, "run-phase-agents.jsonl"),
        Enum.map_join(events, "\n", &Jason.encode!/1)
      )

      summary = TraceReader.run_summary("run-phase-agents", traces_dir: traces_dir)
      assert length(summary.agent_details) == 2
      names = Enum.map(summary.agent_details, & &1.name)
      assert "coder-a" in names
      assert "coder-b" in names
      # Phases should also include agents
      phase = hd(summary.phases)
      assert phase.agents == ["coder-a", "coder-b"]
      assert phase.phase_type == "team"
    end
  end

  describe "agent_transcripts/2" do
    test "parses tool_use blocks from Claude Code session transcripts" do
      tmp_dir = Path.join(System.tmp_dir!(), "transcript_test_#{:rand.uniform(100_000)}")
      lifecycle_dir = Path.join(tmp_dir, "lifecycle")
      projects_dir = Path.join(tmp_dir, "projects")
      project_slug = "-test-project"
      session_dir = Path.join(projects_dir, project_slug)

      File.mkdir_p!(lifecycle_dir)
      File.mkdir_p!(session_dir)

      # Create lifecycle file with session_id mapping
      lifecycle_path = Path.join(lifecycle_dir, "agent-lifecycle.jsonl")

      lifecycle_events = [
        %{
          "event" => "teammate_idle",
          "teammate_name" => "coder-alpha",
          "team_name" => "coding-sprint-abc12345-0",
          "timestamp" => "2026-01-01T00:01:00Z",
          "session_id" => "session-aaa"
        }
      ]

      File.write!(lifecycle_path, Enum.map_join(lifecycle_events, "\n", &Jason.encode!/1))

      # Create mock session transcript with tool_use blocks
      transcript_entries = [
        %{
          "type" => "user",
          "agentName" => "coder-alpha",
          "sessionId" => "session-aaa",
          "message" => %{"role" => "user", "content" => "do the work"},
          "timestamp" => "2026-01-01T00:00:01Z"
        },
        %{
          "type" => "assistant",
          "agentName" => "coder-alpha",
          "sessionId" => "session-aaa",
          "message" => %{
            "role" => "assistant",
            "content" => [
              %{
                "type" => "tool_use",
                "name" => "Write",
                "input" => %{"file_path" => "/app/src/main.ts", "content" => "code"},
                "id" => "t1"
              }
            ]
          },
          "timestamp" => "2026-01-01T00:00:02Z"
        },
        %{
          "type" => "assistant",
          "agentName" => "coder-alpha",
          "sessionId" => "session-aaa",
          "message" => %{
            "role" => "assistant",
            "content" => [
              %{
                "type" => "tool_use",
                "name" => "Bash",
                "input" => %{"command" => "npm test", "description" => "Run tests"},
                "id" => "t2"
              },
              %{
                "type" => "tool_use",
                "name" => "Edit",
                "input" => %{
                  "file_path" => "/app/src/util.ts",
                  "old_string" => "a",
                  "new_string" => "b"
                },
                "id" => "t3"
              }
            ]
          },
          "timestamp" => "2026-01-01T00:00:05Z"
        }
      ]

      File.write!(
        Path.join(session_dir, "session-aaa.jsonl"),
        Enum.map_join(transcript_entries, "\n", &Jason.encode!/1)
      )

      result =
        TraceReader.agent_transcripts(
          "abc12345xyz",
          lifecycle_path: lifecycle_path,
          projects_base: projects_dir,
          project_slug: project_slug
        )

      assert length(result) == 1
      agent = hd(result)
      assert agent.agent_name == "coder-alpha"
      assert length(agent.tool_calls) == 3

      tools = Enum.map(agent.tool_calls, & &1.tool)
      assert "Write" in tools
      assert "Bash" in tools
      assert "Edit" in tools

      # Check detail extraction
      write_call = Enum.find(agent.tool_calls, &(&1.tool == "Write"))
      assert write_call.detail == "main.ts"

      bash_call = Enum.find(agent.tool_calls, &(&1.tool == "Bash"))
      assert bash_call.detail == "Run tests"

      edit_call = Enum.find(agent.tool_calls, &(&1.tool == "Edit"))
      assert edit_call.detail == "util.ts"

      on_exit(fn -> File.rm_rf!(tmp_dir) end)
    end

    test "returns empty list for missing lifecycle file" do
      result =
        TraceReader.agent_transcripts(
          "abc12345",
          lifecycle_path: "/tmp/nonexistent_lifecycle.jsonl",
          projects_base: "/tmp/nonexistent_projects",
          project_slug: "-test"
        )

      assert result == []
    end

    test "returns empty list when transcript file doesn't exist" do
      tmp_dir = Path.join(System.tmp_dir!(), "transcript_miss_#{:rand.uniform(100_000)}")
      lifecycle_dir = Path.join(tmp_dir, "lifecycle")
      File.mkdir_p!(lifecycle_dir)

      lifecycle_path = Path.join(lifecycle_dir, "agent-lifecycle.jsonl")

      lifecycle_events = [
        %{
          "event" => "teammate_idle",
          "teammate_name" => "coder-beta",
          "team_name" => "coding-sprint-def12345-0",
          "timestamp" => "2026-01-01T00:01:00Z",
          "session_id" => "nonexistent-session"
        }
      ]

      File.write!(lifecycle_path, Enum.map_join(lifecycle_events, "\n", &Jason.encode!/1))

      result =
        TraceReader.agent_transcripts(
          "def12345xyz",
          lifecycle_path: lifecycle_path,
          projects_base: "/tmp/nonexistent_projects",
          project_slug: "-test"
        )

      assert result == []

      on_exit(fn -> File.rm_rf!(tmp_dir) end)
    end
  end

  describe "result_for_run/2" do
    test "reads and parses result JSON", %{runs_dir: runs_dir} do
      result = %{"run_id" => "run-1", "status" => "completed", "elapsed_ms" => 5000}
      File.write!(Path.join(runs_dir, "run-1.result.json"), Jason.encode!(result))

      parsed = TraceReader.result_for_run("run-1", runs_dir: runs_dir)
      assert parsed["status"] == "completed"
      assert parsed["elapsed_ms"] == 5000
    end

    test "returns nil for missing result", %{runs_dir: runs_dir} do
      assert TraceReader.result_for_run("nonexistent", runs_dir: runs_dir) == nil
    end
  end
end
