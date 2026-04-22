defmodule Crucible.Jobs.GithubIngestJob do
  @moduledoc """
  Oban periodic job — polls `GITHUB_OWNER/GITHUB_REPO` issues (and PRs) via
  the GitHub REST API and upserts each as an `inbox_items` row with
  `source: "github"`. Dedup is handled by the unique constraint on
  `(source, source_id)`.

  Skips silently when `GITHUB_OWNER` or `GITHUB_REPO` is unset so a fresh
  checkout doesn't error on every tick.
  """

  use Oban.Worker,
    queue: :patrol,
    max_attempts: 2,
    unique: [period: 25 * 60]

  require Logger

  alias Crucible.Inbox.Ingesters.Github

  @impl Oban.Worker
  def perform(_job) do
    with owner when is_binary(owner) and owner != "" <- System.get_env("GITHUB_OWNER"),
         repo when is_binary(repo) and repo != "" <- System.get_env("GITHUB_REPO") do
      {:ok, result} = Github.poll(owner, repo, opts())

      Logger.info(
        "GithubIngestJob: #{owner}/#{repo} ingested=#{result.ingested} " <>
          "skipped=#{result.skipped} errors=#{result.errors}"
      )

      :ok
    else
      _ ->
        Logger.debug("GithubIngestJob: GITHUB_OWNER/GITHUB_REPO unset, skipping")
        :ok
    end
  rescue
    e ->
      Logger.error("GithubIngestJob failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp opts do
    []
    |> maybe_put(:state, System.get_env("GITHUB_INGEST_STATE"))
    |> maybe_put(:since, System.get_env("GITHUB_INGEST_SINCE"))
  end

  defp maybe_put(opts, _k, nil), do: opts
  defp maybe_put(opts, _k, ""), do: opts
  defp maybe_put(opts, k, v), do: Keyword.put(opts, k, v)
end
