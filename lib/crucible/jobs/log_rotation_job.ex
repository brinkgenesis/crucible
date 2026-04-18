defmodule Crucible.Jobs.LogRotationJob do
  @moduledoc """
  Daily log rotation for unbounded JSONL files.

  Targets:
  1. data/audit-log.jsonl — written by AuditTrail module
  2. .claude-flow/logs/cost-events.jsonl — written by cost tracking

  Rotation policy:
  - If a file exceeds `@size_threshold_bytes`, rename it to `{name}.{date}.jsonl`
    and create a fresh empty file in its place.
  - Rotated files older than `@retention_days` are deleted.
  """

  use Oban.Worker,
    queue: :patrol,
    max_attempts: 2

  require Logger

  @size_threshold_bytes 10 * 1024 * 1024
  @retention_days 30

  @impl Oban.Worker
  def perform(_job) do
    repo_root = repo_root()
    date = Date.utc_today() |> Date.to_iso8601()

    files = [
      {"audit-log", Path.join([repo_root, "data", "audit-log.jsonl"])},
      {"cost-events", Path.join([repo_root, ".claude-flow", "logs", "cost-events.jsonl"])}
    ]

    results =
      Enum.map(files, fn {label, path} ->
        {label, maybe_rotate(label, path, date)}
      end)

    Enum.each(files, fn {_label, path} ->
      prune_rotated(path)
    end)

    errors = Enum.filter(results, fn {_, result} -> match?({:error, _}, result) end)

    if errors == [] do
      Logger.info("LogRotationJob: completed for #{date}")
      :ok
    else
      summary =
        Enum.map_join(errors, ", ", fn {label, {:error, reason}} ->
          "#{label}: #{inspect(reason)}"
        end)

      Logger.error("LogRotationJob: partial failure for #{date}: #{summary}")
      {:error, summary}
    end
  end

  # --- Rotation ---

  defp maybe_rotate(label, path, date) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @size_threshold_bytes ->
        rotate(label, path, date)

      {:ok, %{size: size}} ->
        Logger.debug("LogRotationJob: #{label} is #{size} bytes — no rotation needed")
        :ok

      {:error, :enoent} ->
        Logger.debug("LogRotationJob: #{label} does not exist — skipping")
        :ok

      {:error, reason} ->
        Logger.warning("LogRotationJob: could not stat #{label} (#{path}): #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp rotate(label, path, date) do
    dir = Path.dirname(path)
    basename = Path.basename(path, ".jsonl")
    rotated_path = Path.join(dir, "#{basename}.#{date}.jsonl")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.rename(path, rotated_path),
         :ok <- File.write(path, "") do
      Logger.info("LogRotationJob: rotated #{label} → #{rotated_path}")
      {:ok, rotated_path}
    else
      {:error, reason} ->
        Logger.error("LogRotationJob: failed to rotate #{label}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # --- Pruning ---

  defp prune_rotated(path) do
    dir = Path.dirname(path)
    basename = Path.basename(path, ".jsonl")
    cutoff = Date.utc_today() |> Date.add(-@retention_days)

    with {:ok, entries} <- File.ls(dir) do
      for entry <- entries,
          String.starts_with?(entry, basename <> "."),
          date = extract_date(entry, basename),
          older_than?(date, cutoff) do
        target = Path.join(dir, entry)
        File.rm(target)
        Logger.info("LogRotationJob: pruned old rotated file #{target}")
      end
    end

    :ok
  rescue
    e ->
      Logger.warning("LogRotationJob: prune error: #{Exception.message(e)}")
      :ok
  end

  defp extract_date(entry, basename) do
    # Match "{basename}.YYYY-MM-DD.jsonl"
    suffix = String.replace_prefix(entry, basename <> ".", "")

    case Regex.run(~r/^(\d{4}-\d{2}-\d{2})\.jsonl$/, suffix) do
      [_, date_str] -> Date.from_iso8601!(date_str)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp older_than?(nil, _cutoff), do: false
  defp older_than?(date, cutoff), do: Date.compare(date, cutoff) == :lt

  # --- Config ---

  defp repo_root do
    Application.get_env(:crucible, :orchestrator, [])
    |> Keyword.get(:repo_root, File.cwd!())
  end
end
