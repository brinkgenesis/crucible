defmodule Crucible.Jobs.LogRotationJobTest do
  use ExUnit.Case, async: false

  alias Crucible.Jobs.LogRotationJob

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:crucible, :orchestrator, repo_root: tmp_dir)
    on_exit(fn -> Application.delete_env(:crucible, :orchestrator) end)

    data_dir = Path.join(tmp_dir, "data")
    logs_dir = Path.join([tmp_dir, ".claude-flow", "logs"])
    File.mkdir_p!(data_dir)
    File.mkdir_p!(logs_dir)

    %{
      tmp_dir: tmp_dir,
      audit_path: Path.join(data_dir, "audit-log.jsonl"),
      cost_path: Path.join(logs_dir, "cost-events.jsonl")
    }
  end

  describe "perform/1 — small files" do
    test "skips files below threshold", %{audit_path: audit_path, cost_path: cost_path} do
      File.write!(audit_path, "small data")
      File.write!(cost_path, "small data")

      assert :ok = LogRotationJob.perform(%Oban.Job{})

      # Files should still exist, not rotated
      assert File.read!(audit_path) == "small data"
      assert File.read!(cost_path) == "small data"
    end

    test "handles missing files gracefully" do
      assert :ok = LogRotationJob.perform(%Oban.Job{})
    end
  end

  describe "perform/1 — large file rotation" do
    test "rotates file that exceeds 10MB threshold", %{
      audit_path: audit_path,
      cost_path: cost_path
    } do
      # Write >10MB to audit log
      big_data = String.duplicate("x", 11 * 1024 * 1024)
      File.write!(audit_path, big_data)
      File.write!(cost_path, "small")

      assert :ok = LogRotationJob.perform(%Oban.Job{})

      # Original file should now be empty (fresh file created)
      assert File.read!(audit_path) == ""

      # Rotated file should exist with today's date
      date = Date.utc_today() |> Date.to_iso8601()
      rotated = Path.join(Path.dirname(audit_path), "audit-log.#{date}.jsonl")
      assert File.exists?(rotated)
      assert File.stat!(rotated).size > 10_000_000
    end
  end

  describe "perform/1 — pruning old rotated files" do
    test "prunes rotated files older than 30 days", %{audit_path: audit_path} do
      dir = Path.dirname(audit_path)
      File.write!(audit_path, "current")

      # Create old rotated file (40 days ago)
      old_date = Date.utc_today() |> Date.add(-40) |> Date.to_iso8601()
      old_rotated = Path.join(dir, "audit-log.#{old_date}.jsonl")
      File.write!(old_rotated, "old data")

      # Create recent rotated file (5 days ago)
      recent_date = Date.utc_today() |> Date.add(-5) |> Date.to_iso8601()
      recent_rotated = Path.join(dir, "audit-log.#{recent_date}.jsonl")
      File.write!(recent_rotated, "recent data")

      assert :ok = LogRotationJob.perform(%Oban.Job{})

      # Old file should be pruned
      refute File.exists?(old_rotated)
      # Recent file should remain
      assert File.exists?(recent_rotated)
    end
  end
end
