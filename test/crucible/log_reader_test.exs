defmodule Crucible.LogReaderTest do
  use ExUnit.Case, async: true

  alias Crucible.LogReader

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "log_reader_test_#{:rand.uniform(100_000)}")
    logs_dir = tmp_dir
    agents_dir = Path.join(logs_dir, "agents")

    File.mkdir_p!(logs_dir)
    File.mkdir_p!(agents_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{logs_dir: logs_dir, agents_dir: agents_dir}
  end

  describe "read_log/2" do
    test "reads cost events from JSONL", %{logs_dir: logs_dir} do
      events = [
        %{"tool" => "Read", "sessionId" => "s1", "costUsd" => 0.01},
        %{"tool" => "Edit", "sessionId" => "s1", "costUsd" => 0.02}
      ]

      write_jsonl(logs_dir, "cost-events.jsonl", events)

      result = LogReader.read_log(:cost, logs_dir: logs_dir)
      assert length(result) == 2
      assert hd(result)["tool"] == "Read"
    end

    test "reads audit events", %{logs_dir: logs_dir} do
      events = [
        %{"tool" => "Bash", "status" => "success", "durationMs" => 100},
        %{"tool" => "Edit", "status" => "error", "durationMs" => 50}
      ]

      write_jsonl(logs_dir, "audit.jsonl", events)

      result = LogReader.read_log(:audit, logs_dir: logs_dir)
      assert length(result) == 2
      assert List.last(result)["status"] == "error"
    end

    test "respects limit option", %{logs_dir: logs_dir} do
      events = for i <- 1..20, do: %{"index" => i}
      write_jsonl(logs_dir, "audit.jsonl", events)

      result = LogReader.read_log(:audit, logs_dir: logs_dir, limit: 5)
      assert length(result) == 5
      # Should return last 5
      assert List.last(result)["index"] == 20
    end

    test "filters by search query", %{logs_dir: logs_dir} do
      events = [
        %{"tool" => "Bash", "detail" => "npm install"},
        %{"tool" => "Read", "detail" => "reading file"},
        %{"tool" => "Bash", "detail" => "npm test"}
      ]

      write_jsonl(logs_dir, "cost-events.jsonl", events)

      result = LogReader.read_log(:cost, logs_dir: logs_dir, search: "npm")
      assert length(result) == 2
    end

    test "returns empty for unknown log type", %{logs_dir: logs_dir} do
      assert LogReader.read_log(:unknown, logs_dir: logs_dir) == []
    end

    test "returns empty for missing file", %{logs_dir: logs_dir} do
      assert LogReader.read_log(:audit, logs_dir: logs_dir) == []
    end

    test "skips malformed lines", %{logs_dir: logs_dir} do
      content = ~s({"tool":"ok"}\nnot json\n{"tool":"also_ok"})
      File.write!(Path.join(logs_dir, "audit.jsonl"), content)

      result = LogReader.read_log(:audit, logs_dir: logs_dir)
      assert length(result) == 2
    end
  end

  describe "list_agent_logs/1" do
    test "lists agent log files", %{logs_dir: logs_dir, agents_dir: agents_dir} do
      File.write!(Path.join(agents_dir, "agent-abc.jsonl"), ~s({"event":"start"}))
      File.write!(Path.join(agents_dir, "agent-def.jsonl"), ~s({"event":"start"}))

      result = LogReader.list_agent_logs(logs_dir: logs_dir)
      assert length(result) == 2
      ids = Enum.map(result, & &1.id)
      assert "agent-abc" in ids
      assert "agent-def" in ids
    end

    test "excludes team files", %{logs_dir: logs_dir, agents_dir: agents_dir} do
      File.write!(Path.join(agents_dir, "agent-1.jsonl"), ~s({"event":"start"}))
      File.write!(Path.join(agents_dir, "teams-log.jsonl"), ~s({"event":"team"}))

      result = LogReader.list_agent_logs(logs_dir: logs_dir)
      assert length(result) == 1
      assert hd(result).id == "agent-1"
    end

    test "returns empty for missing agents dir", %{logs_dir: logs_dir} do
      File.rm_rf!(Path.join(logs_dir, "agents"))
      assert LogReader.list_agent_logs(logs_dir: logs_dir) == []
    end
  end

  describe "read_agent_log/2" do
    test "reads agent log entries", %{logs_dir: logs_dir, agents_dir: agents_dir} do
      entries = [
        %{"eventType" => "subagent_start", "agentId" => "a1"},
        %{"eventType" => "tool_call", "tool" => "Read"}
      ]

      write_jsonl(agents_dir, "agent-xyz.jsonl", entries)

      result = LogReader.read_agent_log("agent-xyz", logs_dir: logs_dir)
      assert length(result) == 2
      assert hd(result)["eventType"] == "subagent_start"
    end

    test "skips comment headers", %{logs_dir: logs_dir, agents_dir: agents_dir} do
      content =
        "# Agent log header\n# Created at 2026-01-01\n" <>
          ~s({"eventType":"start"}\n{"eventType":"end"})

      File.write!(Path.join(agents_dir, "agent-comm.jsonl"), content)

      result = LogReader.read_agent_log("agent-comm", logs_dir: logs_dir)
      assert length(result) == 2
    end

    test "returns empty for nonexistent agent", %{logs_dir: logs_dir} do
      assert LogReader.read_agent_log("nonexistent", logs_dir: logs_dir) == []
    end
  end

  defp write_jsonl(dir, filename, events) do
    content = Enum.map_join(events, "\n", &Jason.encode!/1)
    File.write!(Path.join(dir, filename), content)
  end
end
