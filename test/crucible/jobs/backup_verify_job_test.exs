defmodule Crucible.Jobs.BackupVerifyJobTest do
  use ExUnit.Case, async: false

  alias Crucible.Jobs.BackupVerifyJob

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:crucible, :backup, dir: tmp_dir)
    on_exit(fn -> Application.delete_env(:crucible, :backup) end)
    %{tmp_dir: tmp_dir}
  end

  describe "perform/1 — postgres verification" do
    test "passes when valid SQL backup exists", %{tmp_dir: tmp_dir} do
      pg_dir = Path.join(tmp_dir, "pg")
      vault_dir = Path.join([tmp_dir, "vault", "2026-03-30"])
      File.mkdir_p!(pg_dir)
      File.mkdir_p!(vault_dir)
      File.write!(Path.join(vault_dir, "note.md"), "content")

      sql =
        "CREATE TABLE users (id serial PRIMARY KEY);\nCOPY users FROM stdin;\n" <>
          String.duplicate("x", 200)

      gz = :zlib.gzip(sql)
      File.write!(Path.join(pg_dir, "2026-03-30.sql.gz"), gz)

      assert :ok = BackupVerifyJob.perform(%Oban.Job{})
    end

    test "fails when backup is too small", %{tmp_dir: tmp_dir} do
      pg_dir = Path.join(tmp_dir, "pg")
      vault_dir = Path.join([tmp_dir, "vault", "2026-03-30"])
      File.mkdir_p!(pg_dir)
      File.mkdir_p!(vault_dir)
      File.write!(Path.join(vault_dir, "note.md"), "content")

      gz = :zlib.gzip("tiny")
      File.write!(Path.join(pg_dir, "2026-03-30.sql.gz"), gz)

      assert {:error, _} = BackupVerifyJob.perform(%Oban.Job{})
    end

    test "fails when backup has no valid SQL tokens", %{tmp_dir: tmp_dir} do
      pg_dir = Path.join(tmp_dir, "pg")
      vault_dir = Path.join([tmp_dir, "vault", "2026-03-30"])
      File.mkdir_p!(pg_dir)
      File.mkdir_p!(vault_dir)
      File.write!(Path.join(vault_dir, "note.md"), "content")

      gz = :zlib.gzip(String.duplicate("not sql at all, just random text here\n", 10))
      File.write!(Path.join(pg_dir, "2026-03-30.sql.gz"), gz)

      assert {:error, _} = BackupVerifyJob.perform(%Oban.Job{})
    end

    test "fails when no pg backup file exists", %{tmp_dir: tmp_dir} do
      pg_dir = Path.join(tmp_dir, "pg")
      vault_dir = Path.join([tmp_dir, "vault", "2026-03-30"])
      File.mkdir_p!(pg_dir)
      File.mkdir_p!(vault_dir)
      File.write!(Path.join(vault_dir, "note.md"), "content")

      assert {:error, _} = BackupVerifyJob.perform(%Oban.Job{})
    end
  end

  describe "perform/1 — vault verification" do
    test "passes when vault backup has entries", %{tmp_dir: tmp_dir} do
      pg_dir = Path.join(tmp_dir, "pg")
      vault_dir = Path.join([tmp_dir, "vault", "2026-03-30"])
      File.mkdir_p!(pg_dir)
      File.mkdir_p!(vault_dir)

      sql = "CREATE TABLE t (id int);\n" <> String.duplicate("data", 50)
      File.write!(Path.join(pg_dir, "2026-03-30.sql.gz"), :zlib.gzip(sql))
      File.write!(Path.join(vault_dir, "note1.md"), "content1")
      File.write!(Path.join(vault_dir, "note2.md"), "content2")

      assert :ok = BackupVerifyJob.perform(%Oban.Job{})
    end

    test "fails when vault backup is empty directory", %{tmp_dir: tmp_dir} do
      pg_dir = Path.join(tmp_dir, "pg")
      vault_dir = Path.join([tmp_dir, "vault", "2026-03-30"])
      File.mkdir_p!(pg_dir)
      File.mkdir_p!(vault_dir)

      sql = "CREATE TABLE t (id int);\n" <> String.duplicate("data", 50)
      File.write!(Path.join(pg_dir, "2026-03-30.sql.gz"), :zlib.gzip(sql))

      assert {:error, _} = BackupVerifyJob.perform(%Oban.Job{})
    end

    test "fails when no vault backup directory exists", %{tmp_dir: tmp_dir} do
      pg_dir = Path.join(tmp_dir, "pg")
      File.mkdir_p!(pg_dir)

      sql = "CREATE TABLE t (id int);\n" <> String.duplicate("data", 50)
      File.write!(Path.join(pg_dir, "2026-03-30.sql.gz"), :zlib.gzip(sql))

      assert {:error, _} = BackupVerifyJob.perform(%Oban.Job{})
    end
  end

  describe "perform/1 — combined" do
    test "fails when both checks fail", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "pg"))
      assert {:error, msg} = BackupVerifyJob.perform(%Oban.Job{})
      assert msg =~ "postgres"
    end
  end
end
