defmodule Crucible.Jobs.CiLogAnalyzerJob do
  @moduledoc """
  Oban periodic job for the CI Log Self-Learning Loop.

  Pipeline: ingest failed runs → review unanalyzed events → surface cards → mark analyzed.

  Runs hourly via Oban cron. Requires `GITHUB_OWNER` and `GITHUB_REPO` env vars,
  or pass `"owner"` and `"repo"` in the job args.
  """

  use Oban.Worker,
    queue: :patrol,
    max_attempts: 2,
    unique: [period: 3600]

  require Logger

  import Ecto.Query

  alias Crucible.CiLog.{CardSurfacer, Ingestor, Reviewer}
  alias Crucible.Repo
  alias Crucible.Schema.CiLogEvent

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    owner = args["owner"] || System.get_env("GITHUB_OWNER")
    repo = args["repo"] || System.get_env("GITHUB_REPO")

    if is_nil(owner) or is_nil(repo) do
      Logger.warning("CiLogAnalyzerJob: GITHUB_OWNER/GITHUB_REPO not set, skipping")
      :ok
    else
      run_pipeline(owner, repo)
    end
  end

  @doc "Run the full CI log analysis pipeline for the given owner/repo."
  @spec run_pipeline(String.t(), String.t()) :: :ok
  def run_pipeline(owner, repo) do
    # Step 1: Ingest new failed runs
    ingest_result =
      case Ingestor.ingest(owner, repo) do
        {:ok, result} ->
          Logger.info(
            "CiLogAnalyzer: ingested=#{result.ingested} skipped=#{result.skipped} errors=#{result.errors}"
          )

          result

        {:error, reason} ->
          Logger.error("CiLogAnalyzer: ingest failed: #{inspect(reason)}")
          %{ingested: 0, skipped: 0, errors: 1, events: []}
      end

    # Step 2: Review all unanalyzed events (including from previous runs)
    unanalyzed = fetch_unanalyzed()

    {reviewed, review_errors} = review_and_surface(unanalyzed)

    Logger.info(
      "CiLogAnalyzer: pipeline complete — " <>
        "ingested=#{ingest_result.ingested} " <>
        "reviewed=#{reviewed} review_errors=#{review_errors}"
    )

    :telemetry.execute(
      [:crucible, :ci_log_analyzer, :complete],
      %{ingested: ingest_result.ingested, reviewed: reviewed, errors: review_errors},
      %{owner: owner, repo: repo}
    )

    :ok
  end

  @doc false
  def fetch_unanalyzed do
    CiLogEvent
    |> where([e], is_nil(e.analyzed_at))
    |> order_by([e], asc: e.created_at)
    |> Repo.all()
  end

  defp review_and_surface(events) do
    Enum.reduce(events, {0, 0}, fn event, {reviewed, errors} ->
      {:ok, analysis} = Reviewer.review(event)

      mark_analyzed(event, analysis)

      context = %{run_id: event.run_id, workflow_name: event.workflow_name}

      case CardSurfacer.surface(analysis, context) do
        {:ok, _card_id} ->
          {reviewed + 1, errors}

        {:error, reason} ->
          Logger.warning("CiLogAnalyzer: card surface failed: #{inspect(reason)}")
          {reviewed + 1, errors + 1}
      end
    end)
  end

  defp mark_analyzed(event, analysis) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    analysis_map = %{
      "category" => analysis.category,
      "severity" => analysis.severity,
      "title" => analysis.title,
      "summary" => analysis.summary,
      "suggested_fix" => analysis.suggested_fix,
      "is_recurring" => analysis.is_recurring
    }

    event
    |> CiLogEvent.changeset(%{analyzed_at: now, analysis: analysis_map})
    |> Repo.update()
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("CiLogAnalyzer: mark_analyzed failed: #{inspect(reason)}")
    end
  end
end
