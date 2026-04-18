defmodule Crucible.CiLog.Ingestor do
  @moduledoc """
  CI Log Ingestor — fetches failed GitHub Actions runs and stores them.

  Port of `lib/ci/log-ingestor.ts` from infra.

  Uses `gh` CLI for GitHub API access (requires GITHUB_TOKEN in env).
  Deduplicates by `run_id` — already-ingested runs are skipped.

  Public API:
    - `ingest/2` — fetch + store failed runs for owner/repo
    - `ingest_runs/1` — parse raw GitHub API response (for testing)
  """

  require Logger

  alias Crucible.Repo
  alias Crucible.Schema.CiLogEvent

  import Ecto.Query

  @max_log_lines 2000
  @runs_per_page 20

  # Strict validation for GitHub owner/repo identifiers passed into `gh api`.
  # Prevents path-traversal (`../`) or query-string injection (`?`) into the URL.
  @identifier_regex ~r/\A[A-Za-z0-9._-]+\z/

  @failure_conclusions MapSet.new(~w(failure cancelled timed_out action_required))

  @type ingest_result :: %{
          ingested: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer(),
          events: [CiLogEvent.t()]
        }

  @doc """
  Fetch up to #{@runs_per_page} recent failed runs via `gh api` and store
  those not yet ingested. Returns ingested/skipped/error counts.
  """
  @spec ingest(String.t(), String.t()) :: {:ok, ingest_result()} | {:error, term()}
  def ingest(owner, repo) when is_binary(owner) and is_binary(repo) do
    cond do
      not Regex.match?(@identifier_regex, owner) -> {:error, :invalid_owner}
      not Regex.match?(@identifier_regex, repo) -> {:error, :invalid_repo}
      true -> do_ingest(owner, repo)
    end
  end

  defp do_ingest(owner, repo) do
    case fetch_runs(owner, repo) do
      {:ok, all_runs} ->
        failed =
          Enum.filter(all_runs, fn run ->
            run["status"] == "completed" &&
              run["conclusion"] != nil &&
              MapSet.member?(@failure_conclusions, run["conclusion"])
          end)

        Logger.info("CI ingest: #{length(all_runs)} total, #{length(failed)} failed")
        {:ok, process_runs(failed, owner, repo)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Parse and filter runs from a decoded GitHub API response (for testing)."
  @spec ingest_runs([map()], String.t(), String.t()) :: ingest_result()
  def ingest_runs(runs, owner, repo) do
    process_runs(runs, owner, repo)
  end

  @doc "Check whether a run_id has already been ingested."
  @spec already_ingested?(String.t()) :: boolean()
  def already_ingested?(run_id) do
    CiLogEvent
    |> where([e], e.run_id == ^run_id)
    |> select([e], e.id)
    |> limit(1)
    |> Repo.one()
    |> is_nil()
    |> Kernel.not()
  rescue
    _ -> false
  end

  @doc "Extract error/failure lines from raw log text."
  @spec build_failure_summary(String.t()) :: String.t()
  def build_failure_summary(raw_log) when is_binary(raw_log) do
    error_lines =
      raw_log
      |> String.split("\n")
      |> Enum.filter(&Regex.match?(~r/error|fail|exception/i, &1))
      |> Enum.take(10)

    case error_lines do
      [] -> "No error lines found"
      lines -> Enum.join(lines, "\n")
    end
  end

  # --- Private ---

  defp fetch_runs(owner, repo) do
    args = ["api", "repos/#{owner}/#{repo}/actions/runs?per_page=#{@runs_per_page}"]

    case System.cmd("gh", args, stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"workflow_runs" => runs}} when is_list(runs) ->
            {:ok, runs}

          {:ok, _} ->
            {:ok, []}

          {:error, reason} ->
            {:error, {:json_decode_error, reason}}
        end

      {output, code} ->
        {:error, {:gh_cli_error, code, String.slice(output, 0, 500)}}
    end
  end

  defp process_runs(failed_runs, owner, repo) do
    result = %{ingested: 0, skipped: 0, errors: 0, events: []}

    Enum.reduce(failed_runs, result, fn run, acc ->
      run_id = to_string(run["id"])

      cond do
        already_ingested?(run_id) ->
          %{acc | skipped: acc.skipped + 1}

        true ->
          case ingest_single_run(run, run_id, owner, repo) do
            {:ok, event} ->
              Logger.info("Ingested CI run #{run_id}: #{run["name"]}")

              %{
                acc
                | ingested: acc.ingested + 1,
                  events: [event | acc.events]
              }

            {:error, reason} ->
              Logger.error("Failed to ingest run #{run_id}: #{inspect(reason)}")
              %{acc | errors: acc.errors + 1}
          end
      end
    end)
    |> Map.update!(:events, &Enum.reverse/1)
  end

  defp ingest_single_run(run, run_id, owner, repo) do
    raw_log = fetch_run_logs(owner, repo, run["id"])
    truncated = truncate_log(raw_log)

    duration =
      case {run["createdAt"] || run["created_at"], run["updatedAt"] || run["updated_at"]} do
        {c, u} when is_binary(c) and is_binary(u) -> compute_duration_ms(c, u)
        _ -> run["runDurationMs"] || run["run_duration_ms"] || 0
      end

    attrs = %{
      run_id: run_id,
      workflow_name: run["name"] || "unknown",
      conclusion: run["conclusion"] || "failure",
      duration_ms: duration,
      failure_summary: build_failure_summary(truncated),
      raw_log: truncated,
      created_at: parse_timestamp(run["createdAt"] || run["created_at"])
    }

    %CiLogEvent{}
    |> CiLogEvent.changeset(attrs)
    |> Repo.insert()
  end

  defp fetch_run_logs(owner, repo, run_id) do
    args = ["api", "repos/#{owner}/#{repo}/actions/runs/#{run_id}/logs"]

    case System.cmd("gh", args, stderr_to_stdout: true) do
      {output, 0} -> output
      _ -> ""
    end
  end

  defp truncate_log(raw_log) do
    lines = String.split(raw_log, "\n")

    if length(lines) > @max_log_lines do
      lines |> Enum.take(-@max_log_lines) |> Enum.join("\n")
    else
      raw_log
    end
  end

  defp compute_duration_ms(created_at, updated_at) do
    with {:ok, c, _} <- DateTime.from_iso8601(created_at),
         {:ok, u, _} <- DateTime.from_iso8601(updated_at) do
      max(0, DateTime.diff(u, c, :millisecond))
    else
      _ -> 0
    end
  end

  defp parse_timestamp(nil), do: DateTime.utc_now()

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
end
