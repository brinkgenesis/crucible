defmodule Crucible.Jobs.InboxScanJob do
  @moduledoc """
  Oban periodic job that runs the inbox scan pipeline.

  Loads unread inbox items, evaluates them via LLM, and creates kanban
  cards for high-scoring items. Runs every 3 hours via Oban cron.
  """

  use Oban.Worker,
    queue: :patrol,
    max_attempts: 2,
    unique: [period: 3 * 3600]

  require Logger

  alias Crucible.Inbox.Scanner

  @impl Oban.Worker
  def perform(_job) do
    {:ok, result} = Scanner.scan()

    Logger.info(
      "InboxScanJob: evaluated=#{result.evaluated} " <>
        "cards=#{result.cards_created} dismissed=#{result.dismissed} " <>
        "review=#{result.for_review} errors=#{result.errors}"
    )

    :ok
  rescue
    e ->
      Logger.error("InboxScanJob: scan failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end
end
