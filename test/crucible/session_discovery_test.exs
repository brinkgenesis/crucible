defmodule Crucible.SessionDiscoveryTest do
  use ExUnit.Case, async: true

  alias Crucible.SessionDiscovery

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "session_disc_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{log_dir: tmp_dir}
  end

  describe "ended_sessions/1" do
    test "returns MapSet of ended session IDs", %{log_dir: log_dir} do
      events = [
        %{"event" => "session_start", "session" => "s1"},
        %{"event" => "session_end", "session" => "s1"},
        %{"event" => "session_start", "session" => "s2"}
      ]

      content = Enum.map_join(events, "\n", &Jason.encode!/1)
      File.write!(Path.join(log_dir, "session-events.jsonl"), content)

      result = SessionDiscovery.ended_sessions(log_dir)
      assert MapSet.member?(result, "s1")
      refute MapSet.member?(result, "s2")
    end

    test "returns empty MapSet when file doesn't exist", %{log_dir: log_dir} do
      result = SessionDiscovery.ended_sessions(log_dir)
      assert result == MapSet.new()
    end

    test "handles malformed lines gracefully", %{log_dir: log_dir} do
      content = ~s({"event":"session_end","session":"s1"}\nnot json\n{"broken":true}\n)
      File.write!(Path.join(log_dir, "session-events.jsonl"), content)

      result = SessionDiscovery.ended_sessions(log_dir)
      assert MapSet.member?(result, "s1")
      assert MapSet.size(result) == 1
    end
  end

  describe "active_processes/0" do
    test "returns a list" do
      result = SessionDiscovery.active_processes()
      assert is_list(result)
    end
  end
end
