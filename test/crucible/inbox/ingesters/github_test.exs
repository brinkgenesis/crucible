defmodule Crucible.Inbox.Ingesters.GithubTest do
  use Crucible.DataCase, async: true

  alias Crucible.Inbox.Ingesters.Github
  alias Crucible.Schema.InboxItem

  @issue %{
    "number" => 42,
    "title" => "Bug: the thing is broken",
    "body" => "Steps to reproduce: ...",
    "state" => "open",
    "html_url" => "https://github.com/acme/widget/issues/42",
    "updated_at" => "2026-04-22T04:00:00Z",
    "user" => %{"login" => "alice"},
    "labels" => [%{"name" => "bug"}, %{"name" => "priority:high"}]
  }

  @pr %{
    "number" => 43,
    "title" => "Fix the thing",
    "body" => "Closes #42",
    "state" => "open",
    "html_url" => "https://github.com/acme/widget/pull/43",
    "updated_at" => "2026-04-22T05:00:00Z",
    "user" => %{"login" => "bob"},
    "labels" => [],
    "pull_request" => %{"url" => "https://api.github.com/repos/acme/widget/pulls/43"}
  }

  defp static_fetcher(items), do: fn _url, _headers -> {:ok, items} end

  describe "poll/3" do
    test "ingests both issues and PRs by default" do
      assert {:ok, result} =
               Github.poll("acme", "widget", fetcher: static_fetcher([@issue, @pr]))

      assert result.ingested == 2
      assert result.errors == 0

      items = Repo.all(InboxItem)
      assert length(items) == 2
      assert Enum.all?(items, &(&1.source == "github"))

      issue = Enum.find(items, &(&1.source_id == "acme/widget#42"))
      assert issue.title == "Bug: the thing is broken"
      assert issue.author == "alice"
      assert issue.metadata["kind"] == "issue"
      assert issue.metadata["labels"] == ["bug", "priority:high"]
      assert issue.extracted_repos == ["acme/widget"]

      pr = Enum.find(items, &(&1.source_id == "acme/widget#43"))
      assert pr.metadata["kind"] == "pr"
      assert pr.author == "bob"
    end

    test "filters out PRs when include_prs: false" do
      assert {:ok, result} =
               Github.poll("acme", "widget",
                 fetcher: static_fetcher([@issue, @pr]),
                 include_prs: false
               )

      assert result.ingested == 1

      [item] = Repo.all(InboxItem)
      assert item.source_id == "acme/widget#42"
      assert item.metadata["kind"] == "issue"
    end

    test "re-polling the same repo is idempotent" do
      fetcher = static_fetcher([@issue, @pr])

      assert {:ok, %{ingested: 2}} = Github.poll("acme", "widget", fetcher: fetcher)

      assert {:ok, result} = Github.poll("acme", "widget", fetcher: fetcher)

      assert result.ingested == 0
      assert result.skipped == 2

      assert Repo.aggregate(InboxItem, :count) == 2
    end

    test "records an error when fetch fails" do
      fetcher = fn _url, _headers -> {:error, :nxdomain} end

      assert {:ok, result} = Github.poll("acme", "widget", fetcher: fetcher)

      assert result.errors == 1
      assert result.ingested == 0
    end

    test "skips items missing an issue number" do
      malformed = %{"title" => "no number here"}

      assert {:ok, result} =
               Github.poll("acme", "widget", fetcher: static_fetcher([malformed, @issue]))

      assert result.ingested == 1
      assert result.errors == 1
    end
  end
end
