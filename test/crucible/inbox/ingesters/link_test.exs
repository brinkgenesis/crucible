defmodule Crucible.Inbox.Ingesters.LinkTest do
  use Crucible.DataCase, async: true

  alias Crucible.Inbox.Ingesters.Link
  alias Crucible.Schema.InboxItem

  describe "ingest/2" do
    test "inserts a link with a fetched title" do
      fetcher = fn _url ->
        {:ok, "<html><head><title>Interesting Post</title></head></html>"}
      end

      assert {:ok, :inserted, item} =
               Link.ingest("https://example.com/post", fetcher: fetcher)

      assert item.source == "link"
      assert item.source_id == "https://example.com/post"
      assert item.title == "Interesting Post"
      assert item.extracted_urls == ["https://example.com/post"]
    end

    test "explicit title skips fetch" do
      fetcher = fn _url -> {:error, :should_not_be_called} end

      assert {:ok, :inserted, item} =
               Link.ingest("https://example.com/post",
                 title: "Manual title",
                 fetcher: fetcher
               )

      assert item.title == "Manual title"
    end

    test "rejects non-http urls" do
      assert {:error, :invalid_url} = Link.ingest("not a url")
      assert {:error, :invalid_url} = Link.ingest("ftp://example.com")
      assert {:error, :invalid_url} = Link.ingest("http://")
    end

    test "second submission of the same url is idempotent" do
      fetcher = fn _url -> {:ok, "<title>Title</title>"} end

      assert {:ok, :inserted, _} =
               Link.ingest("https://example.com/same", fetcher: fetcher)

      assert {:ok, :skipped, _} =
               Link.ingest("https://example.com/same", fetcher: fetcher)

      assert Repo.aggregate(InboxItem, :count) == 1
    end

    test "fetch errors do not block ingestion" do
      fetcher = fn _url -> {:error, :nxdomain} end

      assert {:ok, :inserted, item} =
               Link.ingest("https://example.com/dead", fetcher: fetcher)

      assert item.title == nil
      assert item.source_id == "https://example.com/dead"
    end

    test "note is stored as original_text" do
      assert {:ok, :inserted, item} =
               Link.ingest("https://example.com/note",
                 title: "T",
                 note: "saved for later",
                 fetch_title: false
               )

      assert item.original_text == "saved for later"
    end
  end
end
