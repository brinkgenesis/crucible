defmodule Crucible.LoopDetectorTest do
  use ExUnit.Case, async: true

  alias Crucible.LoopDetector

  # --- detect_edit_loop ---

  describe "detect_edit_loop/1" do
    test "returns empty list when fewer than 5 edits on any file" do
      events =
        for i <- 1..4,
            do: %{file: "app.ex", timestamp: "2026-03-07T00:0#{i}:00Z"}

      assert [] = LoopDetector.detect_edit_loop(events)
    end

    test "returns :warn when a file is edited 5 times" do
      events =
        for i <- 1..5,
            do: %{file: "app.ex", timestamp: "2026-03-07T00:0#{i}:00Z"}

      assert [report] = LoopDetector.detect_edit_loop(events)
      assert report.type == :edit
      assert report.severity == :warn
      assert report.count == 5
      assert report.file == "app.ex"
      assert is_binary(report.suggestion)
    end

    test "returns :error when a file is edited 8+ times" do
      events =
        for i <- 1..8,
            do: %{
              file: "app.ex",
              timestamp: "2026-03-07T00:#{String.pad_leading("#{i}", 2, "0")}:00Z"
            }

      assert [report] = LoopDetector.detect_edit_loop(events)
      assert report.severity == :error
      assert report.count == 8
    end

    test "reports separately per file" do
      events =
        for(_ <- 1..5, do: %{file: "a.ex", timestamp: "2026-03-07T00:00:00Z"}) ++
          for _ <- 1..3, do: %{file: "b.ex", timestamp: "2026-03-07T00:00:00Z"}

      reports = LoopDetector.detect_edit_loop(events)
      assert length(reports) == 1
      assert hd(reports).file == "a.ex"
    end

    test "returns empty list for empty input" do
      assert [] = LoopDetector.detect_edit_loop([])
    end
  end

  # --- detect_semantic_loop ---

  describe "detect_semantic_loop/1" do
    test "detects near-identical edits above 70% similarity" do
      # Same string repeated = 100% cosine similarity
      events =
        for _ <- 1..3 do
          %{file: "app.ex", content_before: "hello world", content_after: "hello world!"}
        end

      assert [report] = LoopDetector.detect_semantic_loop(events)
      assert report.type == :semantic
      assert report.severity == :warn
      assert report.count == 3
      assert report.file == "app.ex"
    end

    test "returns :error at 5+ similar edits" do
      events =
        for _ <- 1..5 do
          %{file: "app.ex", content_before: "abcdefghij", content_after: "abcdefghik"}
        end

      assert [report] = LoopDetector.detect_semantic_loop(events)
      assert report.severity == :error
      assert report.count == 5
    end

    test "does not report dissimilar edits" do
      events =
        for _ <- 1..5 do
          %{
            file: "app.ex",
            content_before: "aaaaaaaaaa",
            content_after: "zzzzzzzzzz"
          }
        end

      assert [] = LoopDetector.detect_semantic_loop(events)
    end

    test "handles empty strings gracefully" do
      events =
        for _ <- 1..4 do
          %{file: "app.ex", content_before: "", content_after: "some content"}
        end

      # Empty strings produce 0.0 similarity, so no report
      assert [] = LoopDetector.detect_semantic_loop(events)
    end

    test "returns empty for fewer than 3 similar edits" do
      events = [
        %{file: "app.ex", content_before: "hello", content_after: "hello!"},
        %{file: "app.ex", content_before: "hello", content_after: "hello!"},
        %{file: "app.ex", content_before: "aaaa", content_after: "zzzz"}
      ]

      assert [] = LoopDetector.detect_semantic_loop(events)
    end
  end

  # --- detect_coordination_loop ---

  describe "detect_coordination_loop/1" do
    test "detects A-B-A ping-pong within 5 minutes" do
      events = [
        %{file: "app.ex", agent_id: "agent-a", timestamp: "2026-03-07T10:00:00Z"},
        %{file: "app.ex", agent_id: "agent-b", timestamp: "2026-03-07T10:01:00Z"},
        %{file: "app.ex", agent_id: "agent-a", timestamp: "2026-03-07T10:02:00Z"}
      ]

      assert [report] = LoopDetector.detect_coordination_loop(events)
      assert report.type == :coordination
      assert report.severity == :warn
      assert report.count == 3
      assert report.file == "app.ex"
      assert "agent-a" in report.agent_ids
      assert "agent-b" in report.agent_ids
    end

    test "does not report when span exceeds 5 minutes" do
      events = [
        %{file: "app.ex", agent_id: "agent-a", timestamp: "2026-03-07T10:00:00Z"},
        %{file: "app.ex", agent_id: "agent-b", timestamp: "2026-03-07T10:03:00Z"},
        %{file: "app.ex", agent_id: "agent-a", timestamp: "2026-03-07T10:06:00Z"}
      ]

      assert [] = LoopDetector.detect_coordination_loop(events)
    end

    test "does not report when same agent edits consecutively" do
      events = [
        %{file: "app.ex", agent_id: "agent-a", timestamp: "2026-03-07T10:00:00Z"},
        %{file: "app.ex", agent_id: "agent-a", timestamp: "2026-03-07T10:01:00Z"},
        %{file: "app.ex", agent_id: "agent-a", timestamp: "2026-03-07T10:02:00Z"}
      ]

      assert [] = LoopDetector.detect_coordination_loop(events)
    end

    test "does not report when files differ" do
      events = [
        %{file: "a.ex", agent_id: "agent-a", timestamp: "2026-03-07T10:00:00Z"},
        %{file: "b.ex", agent_id: "agent-b", timestamp: "2026-03-07T10:01:00Z"},
        %{file: "a.ex", agent_id: "agent-a", timestamp: "2026-03-07T10:02:00Z"}
      ]

      assert [] = LoopDetector.detect_coordination_loop(events)
    end

    test "deduplicates reports for the same file+agent pair" do
      events = [
        %{file: "app.ex", agent_id: "agent-a", timestamp: "2026-03-07T10:00:00Z"},
        %{file: "app.ex", agent_id: "agent-b", timestamp: "2026-03-07T10:01:00Z"},
        %{file: "app.ex", agent_id: "agent-a", timestamp: "2026-03-07T10:02:00Z"},
        %{file: "app.ex", agent_id: "agent-b", timestamp: "2026-03-07T10:03:00Z"},
        %{file: "app.ex", agent_id: "agent-a", timestamp: "2026-03-07T10:04:00Z"}
      ]

      assert [_single_report] = LoopDetector.detect_coordination_loop(events)
    end

    test "returns empty for empty input" do
      assert [] = LoopDetector.detect_coordination_loop([])
    end
  end

  # --- detect_command_loop ---

  describe "detect_command_loop/1" do
    test "returns empty when fewer than 3 failures" do
      events = [
        %{command: "mix test", exit_code: 1},
        %{command: "mix test", exit_code: 1}
      ]

      assert [] = LoopDetector.detect_command_loop(events)
    end

    test "returns :warn at 3 failures" do
      events =
        for _ <- 1..3, do: %{command: "mix test", exit_code: 1}

      assert [report] = LoopDetector.detect_command_loop(events)
      assert report.type == :command
      assert report.severity == :warn
      assert report.count == 3
      assert report.suggestion =~ "mix test"
    end

    test "returns :error at 6+ failures" do
      events =
        for _ <- 1..6, do: %{command: "mix test", exit_code: 1}

      assert [report] = LoopDetector.detect_command_loop(events)
      assert report.severity == :error
      assert report.count == 6
    end

    test "ignores successful commands" do
      events =
        for(_ <- 1..5, do: %{command: "mix test", exit_code: 0}) ++
          [%{command: "mix test", exit_code: 1}]

      assert [] = LoopDetector.detect_command_loop(events)
    end

    test "groups failures by command" do
      events =
        for(_ <- 1..3, do: %{command: "mix test", exit_code: 1}) ++
          for _ <- 1..2, do: %{command: "mix compile", exit_code: 1}

      reports = LoopDetector.detect_command_loop(events)
      assert length(reports) == 1
      assert hd(reports).suggestion =~ "mix test"
    end

    test "returns empty for empty input" do
      assert [] = LoopDetector.detect_command_loop([])
    end
  end

  # --- detect_retry_without_progress ---

  describe "detect_retry_without_progress/1" do
    test "detects stagnant retries (3+ consecutive increases without artifact growth)" do
      events = [
        %{retry_count: 0, artifact_count: 5},
        %{retry_count: 1, artifact_count: 5},
        %{retry_count: 2, artifact_count: 5},
        %{retry_count: 3, artifact_count: 5}
      ]

      assert [report] = LoopDetector.detect_retry_without_progress(events)
      assert report.type == :retry
      assert report.severity == :error
      assert report.count == 3
    end

    test "does not report when artifacts are increasing" do
      events = [
        %{retry_count: 0, artifact_count: 5},
        %{retry_count: 1, artifact_count: 6},
        %{retry_count: 2, artifact_count: 7},
        %{retry_count: 3, artifact_count: 8}
      ]

      assert [] = LoopDetector.detect_retry_without_progress(events)
    end

    test "does not report with fewer than 3 stagnant transitions" do
      events = [
        %{retry_count: 0, artifact_count: 5},
        %{retry_count: 1, artifact_count: 5},
        %{retry_count: 2, artifact_count: 5}
      ]

      # Only 2 stagnant transitions (0->1, 1->2), below threshold
      assert [] = LoopDetector.detect_retry_without_progress(events)
    end

    test "returns empty for single event" do
      assert [] =
               LoopDetector.detect_retry_without_progress([%{retry_count: 0, artifact_count: 5}])
    end

    test "returns empty for empty input" do
      assert [] = LoopDetector.detect_retry_without_progress([])
    end
  end

  # --- run_all ---

  describe "run_all/1" do
    test "runs all detectors and collects reports" do
      events = %{
        edit_events: for(_ <- 1..6, do: %{file: "app.ex", timestamp: "2026-03-07T00:00:00Z"}),
        command_events: for(_ <- 1..4, do: %{command: "mix test", exit_code: 1})
      }

      reports = LoopDetector.run_all(events)
      types = Enum.map(reports, & &1.type)
      assert :edit in types
      assert :command in types
      assert length(reports) == 2
    end

    test "returns empty list for empty map" do
      assert [] = LoopDetector.run_all(%{})
    end

    test "skips detectors with empty event lists" do
      events = %{
        edit_events: [],
        command_events: for(_ <- 1..3, do: %{command: "mix test", exit_code: 1})
      }

      reports = LoopDetector.run_all(events)
      assert length(reports) == 1
      assert hd(reports).type == :command
    end

    test "handles all detector keys" do
      events = %{
        edit_events: [],
        semantic_events: [],
        coordination_events: [],
        command_events: [],
        retry_events: []
      }

      assert [] = LoopDetector.run_all(events)
    end
  end
end
