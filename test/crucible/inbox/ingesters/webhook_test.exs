defmodule Crucible.Inbox.Ingesters.WebhookTest do
  use Crucible.DataCase, async: true

  alias Crucible.Inbox.Ingesters.Webhook
  alias Crucible.Schema.InboxItem

  describe "ingest/1" do
    test "inserts a new webhook item" do
      payload = %{
        "source_id" => "ext-123",
        "title" => "Inbound event",
        "author" => "system",
        "original_text" => "body text",
        "url" => "https://example.com/thing",
        "metadata" => %{"source_system" => "zapier"}
      }

      assert {:ok, :inserted} = Webhook.ingest(payload)

      [item] = Repo.all(InboxItem)
      assert item.source == "webhook"
      assert item.source_id == "ext-123"
      assert item.title == "Inbound event"
      assert item.author == "system"
      assert item.extracted_urls == ["https://example.com/thing"]
      assert item.metadata["source_system"] == "zapier"
    end

    test "second ingestion with same source_id is idempotent" do
      payload = %{"source_id" => "ext-456", "title" => "First"}

      assert {:ok, :inserted} = Webhook.ingest(payload)
      assert {:ok, :skipped} = Webhook.ingest(%{payload | "title" => "Second"})

      [item] = Repo.all(InboxItem)
      # Latest attrs replace the row's mutable fields (title is in @upsert_fields).
      assert item.title == "Second"
    end

    test "rejects missing source_id" do
      assert {:error, :missing_source_id} = Webhook.ingest(%{"title" => "no id"})
      assert {:error, :missing_source_id} = Webhook.ingest(%{"source_id" => ""})
    end

    test "accepts array of urls and repos" do
      payload = %{
        "source_id" => "ext-789",
        "urls" => ["https://a.example", "https://b.example"],
        "repos" => ["acme/one", "acme/two"]
      }

      assert {:ok, :inserted} = Webhook.ingest(payload)

      [item] = Repo.all(InboxItem)
      assert item.extracted_urls == ["https://a.example", "https://b.example"]
      assert item.extracted_repos == ["acme/one", "acme/two"]
    end
  end
end
