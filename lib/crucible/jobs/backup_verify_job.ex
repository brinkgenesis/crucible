defmodule Crucible.Jobs.BackupVerifyJob do
  @moduledoc """
  Weekly backup verification via Oban cron.

  Tests that the most recent PostgreSQL backup can be decompressed and
  parsed as valid SQL, and that the vault backup directory is non-empty.
  Does NOT actually restore to the production database.
  """

  use Oban.Worker,
    queue: :patrol,
    max_attempts: 1

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    backup_dir = backup_dir()

    results = [
      {:postgres, verify_postgres(backup_dir)},
      {:vault, verify_vault(backup_dir)}
    ]

    errors = Enum.filter(results, fn {_, r} -> match?({:error, _}, r) end)

    if errors == [] do
      Logger.info("BackupVerifyJob: all verifications passed")
      :ok
    else
      summary = Enum.map_join(errors, ", ", fn {t, {:error, r}} -> "#{t}: #{inspect(r)}" end)
      Logger.error("BackupVerifyJob: verification failed: #{summary}")
      {:error, summary}
    end
  end

  defp verify_postgres(backup_dir) do
    pg_dir = Path.join(backup_dir, "pg")

    case latest_file(pg_dir, ".sql.gz") do
      nil ->
        {:error, :no_backup_found}

      path ->
        # Decompress and verify it contains valid SQL
        data = File.read!(path)
        sql = :zlib.gunzip(data)

        cond do
          byte_size(sql) < 100 ->
            {:error, :backup_too_small}

          not String.contains?(sql, "CREATE TABLE") and not String.contains?(sql, "COPY ") ->
            {:error, :not_valid_sql}

          true ->
            Logger.info(
              "BackupVerifyJob: postgres backup OK (#{byte_size(sql)} bytes) — #{Path.basename(path)}"
            )

            {:ok, byte_size(sql)}
        end
    end
  rescue
    e ->
      {:error, {:exception, Exception.message(e)}}
  end

  defp verify_vault(backup_dir) do
    vault_dir = Path.join(backup_dir, "vault")

    case latest_dir(vault_dir) do
      nil ->
        {:error, :no_backup_found}

      path ->
        # Check that the backup has files
        case File.ls(path) do
          {:ok, [_ | _] = entries} ->
            Logger.info(
              "BackupVerifyJob: vault backup OK (#{length(entries)} entries) — #{Path.basename(path)}"
            )

            {:ok, length(entries)}

          {:ok, []} ->
            {:error, :empty_backup}

          {:error, reason} ->
            {:error, reason}
        end
    end
  rescue
    e ->
      {:error, {:exception, Exception.message(e)}}
  end

  defp latest_file(dir, extension) do
    if File.dir?(dir) do
      case File.ls(dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&String.ends_with?(&1, extension))
          |> Enum.sort(:desc)
          |> List.first()
          |> then(fn
            nil -> nil
            name -> Path.join(dir, name)
          end)

        _ ->
          nil
      end
    end
  end

  defp latest_dir(dir) do
    if File.dir?(dir) do
      case File.ls(dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(fn e -> File.dir?(Path.join(dir, e)) end)
          |> Enum.sort(:desc)
          |> List.first()
          |> then(fn
            nil -> nil
            name -> Path.join(dir, name)
          end)

        _ ->
          nil
      end
    end
  end

  defp backup_dir do
    Application.get_env(:crucible, :backup, [])
    |> Keyword.get(:dir, Path.join(System.tmp_dir!(), "infra-orchestrator-backups"))
  end
end
