defmodule Crucible.Inbox.Ingesters.RssTest do
  use Crucible.DataCase, async: true

  alias Crucible.Inbox.Ingesters.Rss
  alias Crucible.Schema.InboxItem

  @rss_sample """
  <?xml version="1.0" encoding="UTF-8"?>
  <rss version="2.0">
    <channel>
      <title>Example</title>
      <item>
        <title>First post</title>
        <link>https://example.com/first</link>
        <guid>https://example.com/first</guid>
        <description>The first summary.</description>
        <author>alice@example.com</author>
        <pubDate>Tue, 22 Apr 2026 04:00:00 GMT</pubDate>
      </item>
      <item>
        <title>Second post</title>
        <link>https://example.com/second</link>
        <guid>https://example.com/second</guid>
        <description>Another summary.</description>
      </item>
    </channel>
  </rss>
  """

  @atom_sample """
  <?xml version="1.0" encoding="UTF-8"?>
  <feed xmlns="http://www.w3.org/2005/Atom">
    <title>Example Atom</title>
    <entry>
      <title>Atom entry</title>
      <link href="https://atom.example.com/1"/>
      <id>tag:atom.example.com,2026:1</id>
      <summary>Atom summary.</summary>
      <author><name>Bob</name></author>
      <updated>2026-04-22T04:00:00Z</updated>
    </entry>
  </feed>
  """

  defp static_fetcher(body), do: fn _url -> {:ok, body} end

  describe "ingest/2" do
    test "parses an RSS 2.0 feed and upserts each item" do
      assert {:ok, result} =
               Rss.ingest(["https://example.com/feed"], fetcher: static_fetcher(@rss_sample))

      assert result.feeds == 1
      assert result.ingested == 2
      assert result.errors == 0

      items = Repo.all(InboxItem)
      assert length(items) == 2

      assert Enum.all?(items, &(&1.source == "rss"))
      assert Enum.any?(items, &(&1.title == "First post"))
      assert Enum.any?(items, &(&1.title == "Second post"))
    end

    test "parses an Atom 1.0 feed" do
      assert {:ok, result} =
               Rss.ingest(["https://example.com/atom"], fetcher: static_fetcher(@atom_sample))

      assert result.feeds == 1
      assert result.ingested == 1

      [item] = Repo.all(InboxItem)
      assert item.source == "rss"
      assert item.title == "Atom entry"
      assert item.source_id == "tag:atom.example.com,2026:1"
      assert item.author == "Bob"
    end

    test "re-polling the same feed is idempotent" do
      fetcher = static_fetcher(@rss_sample)

      assert {:ok, %{ingested: 2}} =
               Rss.ingest(["https://example.com/feed"], fetcher: fetcher)

      assert {:ok, result} =
               Rss.ingest(["https://example.com/feed"], fetcher: fetcher)

      assert result.ingested == 0
      assert result.skipped == 2

      assert Repo.aggregate(InboxItem, :count) == 2
    end

    test "records errors when fetch fails" do
      fetcher = fn _ -> {:error, :nxdomain} end

      assert {:ok, result} =
               Rss.ingest(["https://nope.example.com/feed"], fetcher: fetcher)

      assert result.feeds == 1
      assert result.ingested == 0
      assert result.errors == 1
    end

    test "honours max_per_feed" do
      assert {:ok, result} =
               Rss.ingest(["https://example.com/feed"],
                 fetcher: static_fetcher(@rss_sample),
                 max_per_feed: 1
               )

      assert result.ingested == 1
    end
  end
end
