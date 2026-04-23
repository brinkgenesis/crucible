defmodule Crucible.Inbox.Ingesters.Github do
  @moduledoc """
  GitHub issues / PRs ingester.

  `poll/3` hits the GitHub REST API `/repos/{owner}/{repo}/issues` endpoint
  and upserts each returned issue (and/or PR) as an `inbox_items` row with
  `source: "github"` and `source_id: "{owner}/{repo}#<number>"`.

  The GitHub issues list endpoint returns BOTH issues and pull requests — we
  keep both by default so operators can route each appropriately downstream.
  Pass `since_iso8601` to do incremental polls.

  The Oban wrapper `Crucible.Jobs.GithubIngestJob` reads `GITHUB_OWNER` /
  `GITHUB_REPO` / `GITHUB_TOKEN` from env.
  """

  require Logger

  import Ecto.Query

  alias Crucible.Inbox
  alias Crucible.Repo
  alias Crucible.Schema.InboxItem

  @default_req_opts [
    receive_timeout: 15_000,
    retry: false
  ]

  @type poll_result :: %{
          ingested: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }

  @doc """
  Poll issues (and PRs, by default) for a repo and upsert each as an inbox
  item.

  Options:
    * `:token` — GitHub PAT (defaults to `Crucible.Secrets.get("GITHUB_TOKEN")`).
    * `:state` — `"open"` (default), `"closed"`, or `"all"`.
    * `:since` — ISO 8601 timestamp. Only return issues updated at or after.
    * `:include_prs` — `true` (default) keeps PRs; `false` filters them out.
    * `:max_items` — cap (default 50).
    * `:fetcher` — 2-arity stub `(url, headers) -> {:ok, items} | {:error, term}`
      for tests.
  """
  @spec poll(String.t(), String.t(), keyword()) :: {:ok, poll_result()}
  def poll(owner, repo, opts \\ []) when is_binary(owner) and is_binary(repo) do
    token = Keyword.get(opts, :token, Crucible.Secrets.get("GITHUB_TOKEN"))
    state = Keyword.get(opts, :state, "open")
    since = Keyword.get(opts, :since)
    include_prs = Keyword.get(opts, :include_prs, true)
    max_items = Keyword.get(opts, :max_items, 50)
    fetcher = Keyword.get(opts, :fetcher, &default_fetch/2)

    url = build_list_url(owner, repo, state, since, max_items)
    headers = request_headers(token)

    case fetcher.(url, headers) do
      {:ok, items} when is_list(items) ->
        result =
          items
          |> Enum.reject(fn i -> not include_prs and Map.has_key?(i, "pull_request") end)
          |> Enum.reduce(%{ingested: 0, skipped: 0, errors: 0}, fn item, acc ->
            case upsert_issue(item, owner, repo) do
              {:ok, :inserted} -> %{acc | ingested: acc.ingested + 1}
              {:ok, :skipped} -> %{acc | skipped: acc.skipped + 1}
              {:error, _} -> %{acc | errors: acc.errors + 1}
            end
          end)

        {:ok, result}

      {:error, reason} ->
        Logger.warning("Inbox.Github: fetch failed for #{owner}/#{repo}: #{inspect(reason)}")
        {:ok, %{ingested: 0, skipped: 0, errors: 1}}
    end
  end

  # --- Private ---

  defp default_fetch(url, headers) do
    case Req.get(url, Keyword.put(@default_req_opts, :headers, headers)) do
      {:ok, %Req.Response{status: 200, body: body}} when is_list(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, err} ->
        {:error, err}
    end
  end

  defp request_headers(nil), do: base_headers()
  defp request_headers(""), do: base_headers()

  defp request_headers(token) do
    [{"authorization", "Bearer " <> token} | base_headers()]
  end

  defp base_headers do
    [
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"},
      {"user-agent", "crucible-inbox/1"}
    ]
  end

  defp build_list_url(owner, repo, state, since, per_page) do
    base = "https://api.github.com/repos/#{owner}/#{repo}/issues"

    query =
      %{"state" => state, "per_page" => per_page}
      |> maybe_put("since", since)
      |> URI.encode_query()

    base <> "?" <> query
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, _k, ""), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp upsert_issue(item, owner, repo) do
    number = item["number"]

    if is_integer(number) do
      source_id = "#{owner}/#{repo}##{number}"

      existed? =
        InboxItem
        |> where([i], i.source == "github" and i.source_id == ^source_id)
        |> Repo.exists?()

      kind = if Map.has_key?(item, "pull_request"), do: "pr", else: "issue"

      attrs = %{
        source: "github",
        source_id: source_id,
        title: item["title"],
        author: get_in(item, ["user", "login"]),
        original_text: item["body"] || "",
        extracted_urls: [item["html_url"] || ""] |> Enum.reject(&(&1 == "")),
        extracted_repos: ["#{owner}/#{repo}"],
        ingested_at: DateTime.utc_now() |> DateTime.truncate(:second),
        metadata: %{
          kind: kind,
          state: item["state"],
          number: number,
          labels: Enum.map(item["labels"] || [], & &1["name"]),
          html_url: item["html_url"],
          updated_at: item["updated_at"]
        }
      }

      case Inbox.upsert_from_ingestion(attrs) do
        {:ok, _} -> {:ok, if(existed?, do: :skipped, else: :inserted)}
        {:error, cs} -> {:error, cs}
      end
    else
      {:error, :missing_issue_number}
    end
  end
end
