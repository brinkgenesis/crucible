defmodule Crucible.Inbox.Ingesters.Rss do
  @moduledoc """
  RSS / Atom feed ingester.

  `ingest/2` fetches each URL via `Req`, parses it as RSS 2.0 or Atom 1.0,
  and upserts every entry into `inbox_items` with `source: "rss"`. Duplicates
  are collapsed by the `(source, source_id)` unique index, so re-polling a
  feed is idempotent.

  The Oban wrapper `Crucible.Jobs.RssIngestJob` provides scheduling and reads
  the feed list from `INBOX_RSS_FEEDS`.
  """

  require Logger

  import Ecto.Query
  import SweetXml

  alias Crucible.Inbox
  alias Crucible.Repo
  alias Crucible.Schema.InboxItem

  @default_req_opts [
    receive_timeout: 15_000,
    retry: false,
    headers: [{"user-agent", "crucible-inbox/1 (+https://github.com/brinkgenesis/crucible)"}]
  ]

  @type ingest_result :: %{
          feeds: non_neg_integer(),
          ingested: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }

  @doc """
  Poll every URL in `feed_urls` and upsert entries into the inbox.

  Options:
    * `:fetcher` — a 1-arity function `url -> {:ok, body} | {:error, term}`
      for test stubbing. Defaults to a `Req.get/2` call with sensible timeouts.
    * `:max_per_feed` — cap entries per feed (default 25).
  """
  @spec ingest([String.t()], keyword()) :: {:ok, ingest_result()}
  def ingest(feed_urls, opts \\ []) when is_list(feed_urls) do
    max_per_feed = Keyword.get(opts, :max_per_feed, 25)
    fetcher = Keyword.get(opts, :fetcher, &default_fetch/1)

    result = %{feeds: 0, ingested: 0, skipped: 0, errors: 0}

    final =
      Enum.reduce(feed_urls, result, fn url, acc ->
        case fetch_and_parse(url, fetcher) do
          {:ok, entries} ->
            entries
            |> Enum.take(max_per_feed)
            |> Enum.reduce(%{acc | feeds: acc.feeds + 1}, fn entry, a ->
              case upsert_entry(entry, url) do
                {:ok, :inserted} -> %{a | ingested: a.ingested + 1}
                {:ok, :skipped} -> %{a | skipped: a.skipped + 1}
                {:error, _} -> %{a | errors: a.errors + 1}
              end
            end)

          {:error, reason} ->
            Logger.warning("Inbox.Rss: fetch failed for #{url}: #{inspect(reason)}")
            %{acc | errors: acc.errors + 1, feeds: acc.feeds + 1}
        end
      end)

    {:ok, final}
  end

  # --- Private ---

  defp default_fetch(url) do
    case Req.get(url, @default_req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, err} ->
        {:error, err}
    end
  end

  defp fetch_and_parse(url, fetcher) do
    with {:ok, body} <- fetcher.(url) do
      {:ok, parse_feed(body)}
    end
  rescue
    e -> {:error, {:parse_error, Exception.message(e)}}
  end

  # Parses both RSS 2.0 (<rss><channel><item>) and Atom 1.0 (<feed><entry>).
  # Returns a list of entry maps.
  defp parse_feed(body) when is_binary(body) do
    items = xpath(body, ~x"//item"l)

    if items != [] do
      Enum.map(items, &rss_item/1)
    else
      entries = xpath(body, ~x"//*[local-name()='entry']"l)
      Enum.map(entries, &atom_entry/1)
    end
  end

  defp rss_item(item) do
    %{
      title: xpath(item, ~x"./title/text()"s) |> trim(),
      link: xpath(item, ~x"./link/text()"s) |> trim(),
      guid: xpath(item, ~x"./guid/text()"s) |> trim(),
      summary: xpath(item, ~x"./description/text()"s) |> trim(),
      author: xpath(item, ~x"./author/text()"s) |> trim(),
      published_at: xpath(item, ~x"./pubDate/text()"s) |> trim()
    }
  end

  defp atom_entry(entry) do
    %{
      title: xpath(entry, ~x"./*[local-name()='title']/text()"s) |> trim(),
      link: xpath(entry, ~x"./*[local-name()='link']/@href"s) |> trim(),
      guid: xpath(entry, ~x"./*[local-name()='id']/text()"s) |> trim(),
      summary: xpath(entry, ~x"./*[local-name()='summary']/text()"s) |> trim(),
      author:
        xpath(entry, ~x"./*[local-name()='author']/*[local-name()='name']/text()"s) |> trim(),
      published_at: xpath(entry, ~x"./*[local-name()='updated']/text()"s) |> trim()
    }
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp upsert_entry(entry, feed_url) do
    source_id = nil_if_blank(entry.guid) || nil_if_blank(entry.link)

    case source_id do
      nil ->
        {:error, :no_source_id}

      id ->
        existed? =
          InboxItem
          |> where([i], i.source == "rss" and i.source_id == ^id)
          |> Repo.exists?()

        attrs = %{
          source: "rss",
          source_id: id,
          title: nil_if_blank(entry.title),
          author: nil_if_blank(entry.author),
          original_text: entry.summary || "",
          extracted_urls: if(entry.link != "", do: [entry.link], else: []),
          ingested_at: DateTime.utc_now() |> DateTime.truncate(:second),
          metadata: %{
            feed_url: feed_url,
            published_at: entry.published_at
          }
        }

        case Inbox.upsert_from_ingestion(attrs) do
          {:ok, _item} ->
            {:ok, if(existed?, do: :skipped, else: :inserted)}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  defp nil_if_blank(""), do: nil
  defp nil_if_blank(nil), do: nil
  defp nil_if_blank(s) when is_binary(s), do: s
end
