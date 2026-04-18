defmodule Crucible.Claude.OutputParserTest do
  use ExUnit.Case, async: true

  alias Crucible.Claude.OutputParser

  describe "strip_ansi/1" do
    test "strips ANSI escape codes" do
      assert OutputParser.strip_ansi("\e[32mgreen\e[0m") == "green"
      assert OutputParser.strip_ansi("\e[1;31mred bold\e[0m") == "red bold"
      assert OutputParser.strip_ansi("no ansi") == "no ansi"
    end
  end

  describe "extract_urls/1" do
    test "extracts URLs from text" do
      text = "Visit https://example.com and http://other.org/path for details"
      urls = OutputParser.extract_urls(text)
      assert "https://example.com" in urls
      assert "http://other.org/path" in urls
    end

    test "handles ANSI-encoded URLs" do
      text = "\e[34mhttps://claude.ai/share/abc\e[0m"
      urls = OutputParser.extract_urls(text)
      assert "https://claude.ai/share/abc" in urls
    end

    test "returns empty list when no URLs" do
      assert OutputParser.extract_urls("no urls here") == []
    end
  end

  describe "extract_session_url/1" do
    test "extracts Claude session URL" do
      text = "Session: https://claude.ai/share/abc123"
      assert OutputParser.extract_session_url(text) == "https://claude.ai/share/abc123"
    end

    test "returns nil when no session URL" do
      assert OutputParser.extract_session_url("no url") == nil
    end
  end

  describe "extract_cost/1" do
    test "extracts cost amount" do
      assert OutputParser.extract_cost("Total cost: $1.23") == 1.23
      assert OutputParser.extract_cost("$0.05 spent") == 0.05
    end

    test "handles ANSI in cost output" do
      assert OutputParser.extract_cost("\e[33m$2.50\e[0m") == 2.50
    end

    test "returns nil when no cost" do
      assert OutputParser.extract_cost("no cost info") == nil
    end
  end

  describe "extract_tokens/1" do
    test "extracts token counts" do
      assert %{total: 1500} = OutputParser.extract_tokens("1500 tokens total")
      assert %{total: 2000} = OutputParser.extract_tokens("2k tokens total")
    end

    test "returns nil when no tokens" do
      assert %{total: nil} = OutputParser.extract_tokens("no tokens")
    end
  end

  describe "detect_error/1" do
    test "detects error patterns" do
      assert OutputParser.detect_error("Error: something went wrong") =~ "Error:"
      assert OutputParser.detect_error("FATAL crash") =~ "FATAL"
    end

    test "returns nil for clean output" do
      assert OutputParser.detect_error("All good, completed successfully") == nil
    end
  end

  describe "parse_sentinel/2" do
    setup do
      dir = System.tmp_dir!()
      path = Path.join(dir, "test-sentinel-#{:rand.uniform(100_000)}.done")
      on_exit(fn -> File.rm(path) end)
      %{path: path}
    end

    test "returns not_done for missing file", %{path: path} do
      assert :not_done = OutputParser.parse_sentinel(path)
    end

    test "parses plain 'done' sentinel", %{path: path} do
      File.write!(path, "done")
      assert {:ok, %{status: "done"}} = OutputParser.parse_sentinel(path)
    end

    test "parses JSON sentinel with commit hash", %{path: path} do
      File.write!(path, Jason.encode!(%{"commitHash" => "abc123"}))
      assert {:ok, %{status: "done", commit_hash: "abc123"}} = OutputParser.parse_sentinel(path)
    end

    test "rejects stale sentinel matching base commit", %{path: path} do
      File.write!(path, Jason.encode!(%{"commitHash" => "abc123"}))
      assert :not_done = OutputParser.parse_sentinel(path, "abc123")
    end

    test "accepts noChanges sentinel regardless of base commit", %{path: path} do
      File.write!(path, Jason.encode!(%{"commitHash" => "abc123", "noChanges" => true}))
      assert {:ok, %{no_changes: true}} = OutputParser.parse_sentinel(path, "abc123")
    end
  end
end
