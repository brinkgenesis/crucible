defmodule Crucible.Jobs.RssIngestJob do
  @moduledoc """
  Oban periodic job — polls every URL in `INBOX_RSS_FEEDS` (comma-separated)
  and upserts each entry as an `inbox_items` row with `source: "rss"`. The
  scanner picks them up on its next tick; dedup is handled by the unique
  constraint on `(source, source_id)`.

  Skips silently when `INBOX_RSS_FEEDS` is unset so a fresh checkout doesn't
  error every 30 minutes.
  """

  use Oban.Worker,
    queue: :patrol,
    max_attempts: 2,
    unique: [period: 25 * 60]

  require Logger

  alias Crucible.Inbox.Ingesters.Rss

  @impl Oban.Worker
  def perform(_job) do
    case feed_urls() do
      [] ->
        Logger.debug("RssIngestJob: INBOX_RSS_FEEDS unset, skipping")
        :ok

      urls ->
        {:ok, result} = Rss.ingest(urls)

        Logger.info(
          "RssIngestJob: feeds=#{result.feeds} ingested=#{result.ingested} " <>
            "skipped=#{result.skipped} errors=#{result.errors}"
        )

        :ok
    end
  rescue
    e ->
      Logger.error("RssIngestJob failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp feed_urls do
    case System.get_env("INBOX_RSS_FEEDS") do
      nil ->
        []

      "" ->
        []

      raw ->
        raw
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end
end
