defmodule Crucible.TokenMetricsTest do
  use ExUnit.Case, async: true

  alias Crucible.Types.PhaseTokenMetrics
  alias Crucible.Claude.OutputParser

  describe "PhaseTokenMetrics struct" do
    test "defaults are sensible" do
      m = %PhaseTokenMetrics{}
      assert m.session_resumed == false
      assert m.retry_count == 0
      assert m.duration_ms == 0
      assert m.exit_code == nil
      assert m.budget_usd == nil
      assert m.result == nil
    end

    test "can be constructed with values" do
      m = %PhaseTokenMetrics{
        session_resumed: true,
        retry_count: 2,
        duration_ms: 45_000,
        exit_code: 0,
        budget_usd: 10.0,
        result: "done"
      }

      assert m.session_resumed == true
      assert m.retry_count == 2
      assert m.duration_ms == 45_000
      assert m.exit_code == 0
      assert m.budget_usd == 10.0
      assert m.result == "done"
    end

    test "can be converted to map" do
      m = %PhaseTokenMetrics{session_resumed: true, duration_ms: 100}
      map = Map.from_struct(m)
      assert map[:session_resumed] == true
      assert map[:duration_ms] == 100
    end
  end

  describe "OutputParser.extract_session_id/1" do
    test "extracts session ID from Claude URL" do
      output = """
      Working on your task...
      Session: https://claude.ai/chat/abc12345-def6-7890-abcd-ef1234567890
      Done!
      """

      assert OutputParser.extract_session_id(output) == "abc12345-def6-7890-abcd-ef1234567890"
    end

    test "returns nil when no session URL present" do
      assert OutputParser.extract_session_id("No URL here") == nil
    end

    test "handles ANSI-encoded output" do
      output = "\e[32mhttps://claude.ai/chat/dead-beef-1234-5678-abcdef012345\e[0m"
      assert OutputParser.extract_session_id(output) == "dead-beef-1234-5678-abcdef012345"
    end

    test "returns nil for non-chat Claude URLs" do
      output = "Visit https://claude.ai/settings for more"
      assert OutputParser.extract_session_id(output) == nil
    end
  end
end
