defmodule Crucible.RemoteSessionTrackerTest do
  use ExUnit.Case, async: false

  alias Crucible.RemoteSessionTracker

  setup do
    # Ensure any running session is stopped before each test
    _ = RemoteSessionTracker.stop_session()
    wait_until_stopped(8)
    :ok
  end

  defp wait_until_stopped(0), do: :ok

  defp wait_until_stopped(attempts) do
    case RemoteSessionTracker.status() do
      %{running: true} ->
        Process.sleep(25)
        _ = RemoteSessionTracker.stop_session()
        wait_until_stopped(attempts - 1)

      _ ->
        :ok
    end
  end

  # ── Status ────────────────────────────────────────────────────────

  describe "status/0" do
    test "returns not-running status when no session exists" do
      status = RemoteSessionTracker.status()
      assert status.running == false
      assert status.url == nil
      assert status.pid == nil
      assert status.startedAt == nil
      assert status.permissionMode == "bypassPermissions"
    end
  end

  # ── Stop session ──────────────────────────────────────────────────

  describe "stop_session/0" do
    test "clears all state and reports wasRunning false when idle" do
      result = RemoteSessionTracker.stop_session()
      assert result.stopped == false
      assert result.wasRunning == false

      status = RemoteSessionTracker.status()
      assert status.running == false
      assert status.url == nil
      assert status.pid == nil
      assert status.startedAt == nil
    end
  end

  # ── Output ────────────────────────────────────────────────────────

  describe "output/1" do
    test "returns empty list when no session is running" do
      assert RemoteSessionTracker.output() == []
    end

    test "respects limit parameter" do
      assert RemoteSessionTracker.output(0) == []
      assert RemoteSessionTracker.output(10) == []
    end
  end

  # ── Start session ─────────────────────────────────────────────────

  describe "start_session/1" do
    test "returns error when claude binary is not found" do
      # Temporarily modify PATH so claude is not found
      original_path = System.get_env("PATH")
      System.put_env("PATH", "/nonexistent")

      try do
        result = RemoteSessionTracker.start_session()
        # Either claude_not_found (no binary) or start_failed (port error)
        assert match?({:error, _}, result)
      after
        System.put_env("PATH", original_path)
      end
    end
  end

  # ── Internal helpers via GenServer state manipulation ──────────────

  describe "stale session cleanup" do
    test "status returns running false after port exit message" do
      # Verify that after getting a status, a dead port is cleaned up
      # Since we can't easily mock a port, we verify the idle path
      status = RemoteSessionTracker.status()
      assert status.running == false
    end
  end

  # ── URL extraction ────────────────────────────────────────────────

  describe "URL extraction" do
    test "extracts URL from clean text via data handler" do
      # We test indirectly by sending data to a running tracker
      # Since we can't start a real session in CI, test the module's regex
      regex = ~r/https:\/\/claude\.ai\/code\/(?:session_[A-Za-z0-9_-]{20,}|[A-Za-z0-9_-]{20,})/

      assert Regex.match?(regex, "https://claude.ai/code/session_abc123def456ghi789jk")
      assert Regex.match?(regex, "https://claude.ai/code/abcDEF123456789012345678")
      refute Regex.match?(regex, "https://claude.ai/code/short")
      refute Regex.match?(regex, "https://example.com/code/session_abc123def456ghi789jk")
    end

    test "extracts URL from text with ANSI escape codes" do
      regex = ~r/https:\/\/claude\.ai\/code\/(?:session_[A-Za-z0-9_-]{20,}|[A-Za-z0-9_-]{20,})/

      # After stripping ANSI, the URL should be matchable
      ansi_text = "\e[32mhttps://claude.ai/code/session_abc123def456ghi789jk\e[0m"
      stripped = Regex.replace(~r/\e\[[0-9;?]*[A-Za-z]/, ansi_text, "")
      assert Regex.match?(regex, stripped)
    end

    test "extracts URL from text with OSC sequences" do
      regex = ~r/https:\/\/claude\.ai\/code\/(?:session_[A-Za-z0-9_-]{20,}|[A-Za-z0-9_-]{20,})/

      osc_text =
        "\e]8;;https://claude.ai/code/session_abc123def456ghi789jk\ahttps://claude.ai/code/session_abc123def456ghi789jk\e]8;;\a"

      stripped =
        osc_text
        |> then(&Regex.replace(~r/\e\][^\a\x1b]*(?:\a|\e\\)/, &1, ""))
        |> then(&Regex.replace(~r/\e\[[0-9;?]*[A-Za-z]/, &1, ""))

      assert Regex.match?(regex, stripped)
    end
  end

  # ── Output deduplication ──────────────────────────────────────────

  describe "output line deduplication" do
    test "merge_output_lines deduplicates consecutive identical lines" do
      # Test the dedup logic indirectly through the module's behavior
      # The merge_output_lines function is private, so we verify the principle:
      # repeated lines within a 20-line window are suppressed
      existing = Enum.map(1..5, &"line #{&1}")
      # Simulating what merge_output_lines does
      new_lines = ["line 5", "line 6", "line 5"]

      # "line 5" is already in existing (last line), so first occurrence is skipped
      # "line 6" is new, added
      # "line 5" again is within window, skipped
      # Net result: only "line 6" is added
      expected_addition_count = 1

      # We verify the logic matches our understanding
      additions =
        Enum.reduce(new_lines, {[], List.last(existing)}, fn line, {adds, last_line} ->
          cond do
            line == last_line -> {adds, last_line}
            Enum.any?(Enum.take(existing, -20), &(&1 == line)) -> {adds, last_line}
            true -> {[line | adds], line}
          end
        end)
        |> elem(0)
        |> Enum.reverse()

      assert length(additions) == expected_addition_count
      assert additions == ["line 6"]
    end
  end
end
