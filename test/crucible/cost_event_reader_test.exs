defmodule Crucible.CostEventReaderTest do
  use ExUnit.Case, async: true

  alias Crucible.CostEventReader

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "cost_reader_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    file_path = Path.join(tmp_dir, "cost-events.jsonl")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir, file_path: file_path}
  end

  defp start_reader(file_path) do
    name = :"cost_reader_#{:rand.uniform(100_000)}"
    {:ok, pid} = GenServer.start_link(CostEventReader, [file_path: file_path], name: name)
    pid
  end

  defp write_events(file_path, events) do
    content = Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n"
    File.write!(file_path, content)
  end

  describe "JSONL parsing and session aggregation" do
    test "parses events and groups by session", %{file_path: file_path} do
      events = [
        %{"session" => "s1", "tool" => "Read", "timestamp" => "2026-01-01T00:00:01Z"},
        %{"session" => "s1", "tool" => "Edit", "timestamp" => "2026-01-01T00:00:02Z"},
        %{"session" => "s2", "tool" => "Bash", "timestamp" => "2026-01-01T00:00:03Z"}
      ]

      write_events(file_path, events)
      pid = start_reader(file_path)

      sessions = GenServer.call(pid, {:all_sessions, []})
      assert length(sessions) == 2

      s1 = Enum.find(sessions, &(&1.session_id == "s1"))
      assert s1.tool_count == 2
      assert s1.last_tool == "Edit"

      s2 = Enum.find(sessions, &(&1.session_id == "s2"))
      assert s2.tool_count == 1
    end

    test "skips malformed lines", %{file_path: file_path} do
      content =
        ~s({"session":"s1","tool":"Read","timestamp":"2026-01-01T00:00:01Z"}\nnot json\n{"broken":true}\n)

      File.write!(file_path, content)
      pid = start_reader(file_path)

      sessions = GenServer.call(pid, {:all_sessions, []})
      assert length(sessions) == 1
    end

    test "tracks cost data", %{file_path: file_path} do
      events = [
        %{
          "session" => "s1",
          "tool" => "Read",
          "timestamp" => "2026-01-01T00:00:01Z",
          "costUsd" => 0.05,
          "inputTokens" => 1000,
          "outputTokens" => 500
        },
        %{
          "session" => "s1",
          "tool" => "Edit",
          "timestamp" => "2026-01-01T00:00:02Z",
          "costUsd" => 0.03,
          "inputTokens" => 800,
          "outputTokens" => 300
        }
      ]

      write_events(file_path, events)
      pid = start_reader(file_path)

      sessions = GenServer.call(pid, {:all_sessions, []})
      s1 = hd(sessions)
      assert_in_delta s1.total_cost_usd, 0.08, 0.001
      assert s1.total_input_tokens == 1800
      assert s1.total_output_tokens == 800
    end
  end

  describe "sessions_for_run/1" do
    test "filters sessions by run_id prefix", %{file_path: file_path} do
      events = [
        %{
          "session" => "s1",
          "tool" => "Read",
          "timestamp" => "2026-01-01T00:00:01Z",
          "runId" => "abc12345-full-id"
        },
        %{
          "session" => "s2",
          "tool" => "Edit",
          "timestamp" => "2026-01-01T00:00:02Z",
          "runId" => "def67890-full-id"
        }
      ]

      write_events(file_path, events)
      pid = start_reader(file_path)

      result = GenServer.call(pid, {:sessions_for_run, "abc12345"})
      assert length(result) == 1
      assert hd(result).session_id == "s1"
    end
  end

  describe "session_events/2" do
    test "returns events for a session", %{file_path: file_path} do
      events = [
        %{"session" => "s1", "tool" => "Read", "timestamp" => "2026-01-01T00:00:01Z"},
        %{"session" => "s1", "tool" => "Edit", "timestamp" => "2026-01-01T00:00:02Z"},
        %{"session" => "s2", "tool" => "Bash", "timestamp" => "2026-01-01T00:00:03Z"}
      ]

      write_events(file_path, events)
      pid = start_reader(file_path)

      result = GenServer.call(pid, {:session_events, "s1", []})
      assert length(result) == 2
      assert Enum.all?(result, &(&1.session_id == "s1"))
    end

    test "returns empty list for unknown session", %{file_path: file_path} do
      write_events(file_path, [
        %{"session" => "s1", "tool" => "Read", "timestamp" => "2026-01-01T00:00:01Z"}
      ])

      pid = start_reader(file_path)

      result = GenServer.call(pid, {:session_events, "nonexistent", []})
      assert result == []
    end
  end

  describe "stats/0" do
    test "returns summary stats", %{file_path: file_path} do
      events = [
        %{
          "session" => "s1",
          "tool" => "Read",
          "timestamp" => "2026-01-01T00:00:01Z",
          "costUsd" => 0.1
        },
        %{
          "session" => "s1",
          "tool" => "Edit",
          "timestamp" => "2026-01-01T00:00:02Z",
          "costUsd" => 0.2
        },
        %{
          "session" => "s2",
          "tool" => "Bash",
          "timestamp" => "2026-01-01T00:00:03Z",
          "costUsd" => 0.05
        }
      ]

      write_events(file_path, events)
      pid = start_reader(file_path)

      stats = GenServer.call(pid, :stats)
      assert stats.total_sessions == 2
      assert stats.total_tool_calls == 3
      assert_in_delta stats.total_cost, 0.35, 0.001
    end
  end

  describe "handles missing file" do
    test "starts cleanly when file does not exist" do
      pid = start_reader("/tmp/does_not_exist_#{:rand.uniform(100_000)}.jsonl")
      sessions = GenServer.call(pid, {:all_sessions, []})
      assert sessions == []
    end
  end
end
