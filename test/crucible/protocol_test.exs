defmodule Crucible.Claude.ProtocolTest do
  use ExUnit.Case, async: true

  alias Crucible.Claude.Protocol

  @tmp_dir System.tmp_dir!()

  setup do
    test_dir = Path.join(@tmp_dir, "protocol_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(test_dir)
    on_exit(fn -> File.rm_rf!(test_dir) end)
    {:ok, dir: test_dir}
  end

  describe "sentinel_path/3" do
    test "builds correct path" do
      assert Protocol.sentinel_path("/runs", "abc123", "phase-0") ==
               "/runs/abc123-phase-0.done"
    end
  end

  describe "write_sentinel/2 and read_sentinel/2" do
    test "writes and reads simple sentinel", %{dir: dir} do
      path = Path.join(dir, "test.done")
      assert :ok = Protocol.write_sentinel(path)
      assert {:ok, %{status: "done", commit_hash: nil}} = Protocol.read_sentinel(path)
    end

    test "writes and reads JSON sentinel with commit hash", %{dir: dir} do
      path = Path.join(dir, "test.done")
      Protocol.write_sentinel(path, %{commitHash: "abc123", noChanges: false})
      assert {:ok, %{status: "done", commit_hash: "abc123"}} = Protocol.read_sentinel(path)
    end

    test "returns :not_found for missing file" do
      assert :not_found = Protocol.read_sentinel("/nonexistent/path.done")
    end

    test "detects stale sentinel when commit matches base", %{dir: dir} do
      path = Path.join(dir, "test.done")
      Protocol.write_sentinel(path, %{commitHash: "deadbeef"})
      assert :stale = Protocol.read_sentinel(path, "deadbeef")
    end

    test "allows sentinel with noChanges even when commit matches base", %{dir: dir} do
      path = Path.join(dir, "test.done")
      Protocol.write_sentinel(path, %{commitHash: "deadbeef", noChanges: true})
      assert {:ok, %{no_changes: true}} = Protocol.read_sentinel(path, "deadbeef")
    end

    test "non-stale when commits differ", %{dir: dir} do
      path = Path.join(dir, "test.done")
      Protocol.write_sentinel(path, %{commitHash: "abc123"})
      assert {:ok, _} = Protocol.read_sentinel(path, "deadbeef")
    end
  end

  describe "remove_sentinel/1" do
    test "removes file", %{dir: dir} do
      path = Path.join(dir, "test.done")
      File.write!(path, "done")
      assert :ok = Protocol.remove_sentinel(path)
      refute File.exists?(path)
    end

    test "ok when file doesn't exist" do
      assert :ok = Protocol.remove_sentinel("/nonexistent/path.done")
    end
  end

  describe "read_review_verdict/1" do
    test "parses PASS verdict", %{dir: dir} do
      path = Path.join(dir, "verdict.md")
      File.write!(path, "GATE: PASS\n\nAll checks passed.")
      assert :pass = Protocol.read_review_verdict(path)
    end

    test "parses PASS_WITH_CONCERNS verdict", %{dir: dir} do
      path = Path.join(dir, "verdict.md")
      File.write!(path, "GATE: PASS_WITH_CONCERNS\n\nMinor issues found.")
      assert :pass_with_concerns = Protocol.read_review_verdict(path)
    end

    test "parses BLOCK verdict", %{dir: dir} do
      path = Path.join(dir, "verdict.md")
      File.write!(path, "GATE: BLOCK\n\nCritical issues.")
      assert :block = Protocol.read_review_verdict(path)
    end

    test "detects STATUS: *BLOCK in individual verdicts", %{dir: dir} do
      path = Path.join(dir, "verdict.md")
      File.write!(path, "Some review\nSTATUS: *BLOCK\nReason: failed tests")
      assert :block = Protocol.read_review_verdict(path)
    end

    test "defaults to :block for missing file" do
      assert :block = Protocol.read_review_verdict("/nonexistent")
    end

    test "defaults to :block for malformed content", %{dir: dir} do
      path = Path.join(dir, "verdict.md")
      File.write!(path, "this is just some random text")
      assert :block = Protocol.read_review_verdict(path)
    end
  end

  describe "verdict_path/3" do
    test "builds correct path" do
      assert Protocol.verdict_path("/runs", "abc", "p0") ==
               "/runs/abc-p0.verdicts.md"
    end
  end

  describe "read_team_tasks/1" do
    test "returns empty for nonexistent team" do
      result = Protocol.read_team_tasks("nonexistent_team_#{:erlang.unique_integer([:positive])}")
      assert result.exists == false
      assert result.total == 0
    end
  end

  describe "team_config_exists?/1" do
    test "returns false for nonexistent team" do
      refute Protocol.team_config_exists?(
               "nonexistent_team_#{:erlang.unique_integer([:positive])}"
             )
    end
  end
end
