defmodule Crucible.Jobs.BackupJob do
  @moduledoc """
  Daily automated backup via Oban cron.

  Targets:
  1. PostgreSQL — pg_dump piped to gzip
  2. Obsidian vault — rsync to backup directory
  3. Mnesia — :mnesia.backup to timestamped file

  Each target runs independently; one failure doesn't block others.
  Old backups beyond `retention_days` are pruned after each run.
  """

  use Oban.Worker,
    queue: :patrol,
    max_attempts: 2

  require Logger

  @default_retention_days 7

  @impl Oban.Worker
  def perform(_job) do
    backup_dir = backup_dir()
    date = Date.utc_today() |> Date.to_iso8601()

    results = [
      {:postgres, backup_postgres(backup_dir, date)},
      {:vault, backup_vault(backup_dir, date)},
      {:mnesia, backup_mnesia(backup_dir, date)}
    ]

    prune_old_backups(backup_dir)

    errors = Enum.filter(results, fn {_, result} -> match?({:error, _}, result) end)

    if errors == [] do
      :telemetry.execute(
        [:crucible, :backup, :success],
        %{timestamp: System.system_time(:second)},
        %{}
      )

      Logger.info("BackupJob: all backups completed for #{date}")
      :ok
    else
      error_summary =
        Enum.map_join(errors, ", ", fn {target, {:error, reason}} ->
          "#{target}: #{inspect(reason)}"
        end)

      Logger.error("BackupJob: partial failure for #{date}: #{error_summary}")
      {:error, error_summary}
    end
  end

  # --- PostgreSQL ---

  defp backup_postgres(backup_dir, date) do
    dir = Path.join(backup_dir, "pg")
    File.mkdir_p!(dir)
    output_path = Path.join(dir, "#{date}.sql.gz")

    database_url =
      Application.get_env(:crucible, Crucible.Repo, [])
      |> Keyword.get(:url)

    unless database_url do
      Logger.warning("BackupJob: skipping pg_dump — no DATABASE_URL configured")
      {:error, :no_database_url}
    else
      pg_dump = System.find_executable("pg_dump") || "pg_dump"

      case System.cmd(pg_dump, ["--no-owner", "--no-acl", database_url],
             stderr_to_stdout: true,
             into: []
           ) do
        {lines, 0} ->
          File.write!(output_path, :zlib.gzip(Enum.join(lines)))
          Logger.info("BackupJob: pg_dump → #{output_path}")
          {:ok, output_path}

        {output, code} ->
          Logger.error(
            "BackupJob: pg_dump failed (#{code}): #{Enum.take(output, 3) |> Enum.join()}"
          )

          {:error, {:pg_dump_failed, code}}
      end
    end
  rescue
    e ->
      Logger.error("BackupJob: pg_dump error: #{Exception.message(e)}")
      {:error, {:exception, Exception.message(e)}}
  end

  # --- Obsidian Vault ---

  defp backup_vault(backup_dir, date) do
    vault_path = vault_path()
    dest = Path.join([backup_dir, "vault", date])

    unless File.dir?(vault_path) do
      Logger.warning("BackupJob: skipping vault backup — #{vault_path} not found")
      {:error, :vault_not_found}
    else
      File.mkdir_p!(dest)

      case System.cmd("rsync", ["-a", "--delete", vault_path <> "/", dest <> "/"],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          Logger.info("BackupJob: vault rsync → #{dest}")
          {:ok, dest}

        {output, code} ->
          Logger.error("BackupJob: rsync failed (#{code}): #{String.trim(output)}")
          {:error, {:rsync_failed, code}}
      end
    end
  rescue
    e ->
      Logger.error("BackupJob: vault backup error: #{Exception.message(e)}")
      {:error, {:exception, Exception.message(e)}}
  end

  # --- Mnesia ---

  defp backup_mnesia(backup_dir, date) do
    dir = Path.join(backup_dir, "mnesia")
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{date}.bak")

    case :mnesia.backup(String.to_charlist(path)) do
      :ok ->
        Logger.info("BackupJob: mnesia backup → #{path}")
        {:ok, path}

      {:error, reason} ->
        Logger.warning("BackupJob: mnesia backup skipped: #{inspect(reason)}")
        {:error, {:mnesia, reason}}
    end
  rescue
    e ->
      Logger.warning("BackupJob: mnesia backup error: #{Exception.message(e)}")
      {:error, {:exception, Exception.message(e)}}
  end

  # --- Retention ---

  defp prune_old_backups(backup_dir) do
    retention = retention_days()
    cutoff = Date.utc_today() |> Date.add(-retention)

    for subdir <- ["pg", "vault", "mnesia"],
        full_path = Path.join(backup_dir, subdir),
        File.dir?(full_path),
        {:ok, entries} = File.ls(full_path),
        entry <- entries,
        date_from_entry(entry) |> older_than?(cutoff) do
      target = Path.join(full_path, entry)
      File.rm_rf!(target)
      Logger.info("BackupJob: pruned old backup #{target}")
    end

    :ok
  rescue
    e ->
      Logger.warning("BackupJob: prune error: #{Exception.message(e)}")
      :ok
  end

  defp date_from_entry(entry) do
    # Extract YYYY-MM-DD from filenames like "2026-03-29.sql.gz" or directory "2026-03-29"
    case Regex.run(~r/^(\d{4}-\d{2}-\d{2})/, entry) do
      [_, date_str] -> Date.from_iso8601!(date_str)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp older_than?(nil, _cutoff), do: false
  defp older_than?(date, cutoff), do: Date.compare(date, cutoff) == :lt

  # --- Config ---

  defp backup_dir do
    Application.get_env(:crucible, :backup, [])
    |> Keyword.get(:dir, Path.join(System.tmp_dir!(), "infra-orchestrator-backups"))
  end

  defp vault_path do
    Application.get_env(:crucible, :backup, [])
    |> Keyword.get(:vault_path, Path.expand("../../memory", __DIR__))
  end

  defp retention_days do
    Application.get_env(:crucible, :backup, [])
    |> Keyword.get(:retention_days, @default_retention_days)
  end
end
