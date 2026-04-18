defmodule Crucible.Jobs.BackupJobTest do
  use ExUnit.Case, async: true

  alias Crucible.Jobs.BackupJob

  @moduletag :tmp_dir

  describe "perform/1" do
    test "creates backup directory structure", %{tmp_dir: tmp_dir} do
      Application.put_env(:crucible, :backup, dir: tmp_dir, vault_path: tmp_dir)

      on_exit(fn ->
        Application.delete_env(:crucible, :backup)
      end)

      # perform will fail on pg_dump (no real DB URL in test) but should create directories
      BackupJob.perform(%Oban.Job{})

      assert File.dir?(Path.join(tmp_dir, "pg"))
      assert File.dir?(Path.join(tmp_dir, "mnesia"))
    end
  end

  describe "retention pruning" do
    test "prunes backup files older than retention window", %{tmp_dir: tmp_dir} do
      Application.put_env(:crucible, :backup,
        dir: tmp_dir,
        vault_path: tmp_dir,
        retention_days: 3
      )

      on_exit(fn ->
        Application.delete_env(:crucible, :backup)
      end)

      pg_dir = Path.join(tmp_dir, "pg")
      File.mkdir_p!(pg_dir)

      # Create old and recent backup files
      old_date = Date.utc_today() |> Date.add(-10) |> Date.to_iso8601()
      recent_date = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()
      today_date = Date.utc_today() |> Date.to_iso8601()

      File.write!(Path.join(pg_dir, "#{old_date}.sql.gz"), "old")
      File.write!(Path.join(pg_dir, "#{recent_date}.sql.gz"), "recent")
      File.write!(Path.join(pg_dir, "#{today_date}.sql.gz"), "today")

      # Run backup (will partially fail but pruning still runs)
      BackupJob.perform(%Oban.Job{})

      # Old file should be pruned
      refute File.exists?(Path.join(pg_dir, "#{old_date}.sql.gz"))
      # Recent files should remain
      assert File.exists?(Path.join(pg_dir, "#{recent_date}.sql.gz"))
      assert File.exists?(Path.join(pg_dir, "#{today_date}.sql.gz"))
    end
  end
end
