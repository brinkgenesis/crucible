defmodule Crucible.Inbox.Ingesters.Link do
  @moduledoc """
  Ingester for raw URL drops — a user-facing "save this link for later"
  flow. `ingest/2` normalises the URL, optionally fetches it to extract
  an HTML `<title>`, and upserts an `inbox_items` row with
  `source: "link"` and `source_id: <canonical url>`.

  Duplicates collapse by the `(source, source_id)` unique index, so the
  same link can be submitted twice without creating two rows.
  """

  require Logger

  import Ecto.Query

  alias Crucible.Inbox
  alias Crucible.Repo
  alias Crucible.Schema.InboxItem

  @default_req_opts [
    receive_timeout: 10_000,
    retry: false,
    headers: [{"user-agent", "crucible-inbox/1"}]
  ]

  @type ingest_result ::
          {:ok, :inserted | :skipped, InboxItem.t()}
          | {:error, :invalid_url | Ecto.Changeset.t()}

  @doc """
  Options:
    * `:title` — skip HTML fetch, use this title instead.
    * `:author` — who submitted the link.
    * `:note` — user-provided note stored as `original_text`.
    * `:fetch_title` — `true` (default) fetches the URL to extract `<title>`.
    * `:fetcher` — 1-arity stub `url -> {:ok, body} | {:error, term}` for tests.
  """
  @spec ingest(String.t(), keyword()) :: ingest_result()
  def ingest(url, opts \\ []) when is_binary(url) do
    case normalise_url(url) do
      {:ok, canonical} ->
        do_ingest(canonical, opts)

      :error ->
        {:error, :invalid_url}
    end
  end

  # --- Private ---

  defp do_ingest(url, opts) do
    fetch_title? = Keyword.get(opts, :fetch_title, true) and is_nil(opts[:title])
    fetcher = Keyword.get(opts, :fetcher, &default_fetch/1)

    title =
      cond do
        is_binary(opts[:title]) and opts[:title] != "" -> opts[:title]
        fetch_title? -> fetch_html_title(url, fetcher)
        true -> nil
      end

    existed? =
      InboxItem
      |> where([i], i.source == "link" and i.source_id == ^url)
      |> Repo.exists?()

    attrs = %{
      source: "link",
      source_id: url,
      title: title,
      author: Keyword.get(opts, :author),
      original_text: Keyword.get(opts, :note, "") || "",
      extracted_urls: [url],
      ingested_at: DateTime.utc_now() |> DateTime.truncate(:second),
      metadata: %{submitted_at: DateTime.utc_now() |> DateTime.to_iso8601()}
    }

    case Inbox.upsert_from_ingestion(attrs) do
      {:ok, item} -> {:ok, if(existed?, do: :skipped, else: :inserted), item}
      {:error, cs} -> {:error, cs}
    end
  end

  defp normalise_url(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, String.trim(url)}

      _ ->
        :error
    end
  end

  defp fetch_html_title(url, fetcher) do
    case fetcher.(url) do
      {:ok, body} when is_binary(body) -> extract_title(body)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp extract_title(html) when is_binary(html) do
    case Regex.run(~r{<title[^>]*>([\s\S]*?)</title>}i, html) do
      [_, title] ->
        title
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> case do
          "" -> nil
          t -> t
        end

      _ ->
        nil
    end
  end

  defp default_fetch(url) do
    case Req.get(url, @default_req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, err} -> {:error, err}
    end
  end
end
