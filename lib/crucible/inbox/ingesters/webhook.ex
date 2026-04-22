defmodule Crucible.Inbox.Ingesters.Webhook do
  @moduledoc """
  Pure ingestion logic for inbound webhook payloads.

  The controller at `CrucibleWeb.Api.InboxIngestController` verifies the
  HMAC signature, then hands the decoded body here. `ingest/1` normalises
  the payload into an `inbox_items` row with `source: "webhook"` and
  upserts via `Crucible.Inbox.upsert_from_ingestion/1`.

  Expected payload shape (all fields optional except `source_id`):

      {
        "source_id": "stable-external-id",
        "title": "...",
        "author": "...",
        "original_text": "...",
        "url": "https://...",
        "urls": ["https://..."],
        "repos": ["org/repo"],
        "metadata": {"arbitrary": "json"}
      }
  """

  import Ecto.Query

  alias Crucible.Inbox
  alias Crucible.Repo
  alias Crucible.Schema.InboxItem

  @type ingest_result ::
          {:ok, :inserted | :skipped} | {:error, :missing_source_id | Ecto.Changeset.t()}

  @spec ingest(map()) :: ingest_result()
  def ingest(payload) when is_map(payload) do
    case fetch_source_id(payload) do
      nil ->
        {:error, :missing_source_id}

      id ->
        existed? =
          InboxItem
          |> where([i], i.source == "webhook" and i.source_id == ^id)
          |> Repo.exists?()

        attrs = build_attrs(id, payload)

        case Inbox.upsert_from_ingestion(attrs) do
          {:ok, _} -> {:ok, if(existed?, do: :skipped, else: :inserted)}
          {:error, cs} -> {:error, cs}
        end
    end
  end

  # --- Private ---

  defp fetch_source_id(payload) do
    payload
    |> Map.get("source_id")
    |> nil_if_blank()
  end

  defp build_attrs(id, payload) do
    url = nil_if_blank(payload["url"])
    extra_urls = payload |> Map.get("urls", []) |> List.wrap() |> Enum.reject(&blank?/1)
    urls = Enum.uniq([url | extra_urls] |> Enum.reject(&is_nil/1))
    repos = payload |> Map.get("repos", []) |> List.wrap() |> Enum.reject(&blank?/1)

    %{
      source: "webhook",
      source_id: id,
      title: nil_if_blank(payload["title"]),
      author: nil_if_blank(payload["author"]),
      original_text: payload["original_text"] || "",
      extracted_urls: urls,
      extracted_repos: repos,
      ingested_at: DateTime.utc_now() |> DateTime.truncate(:second),
      metadata: Map.get(payload, "metadata", %{}) |> ensure_map()
    }
  end

  defp ensure_map(m) when is_map(m), do: m
  defp ensure_map(_), do: %{}

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp nil_if_blank(nil), do: nil
  defp nil_if_blank(""), do: nil
  defp nil_if_blank(s) when is_binary(s), do: s
  defp nil_if_blank(_), do: nil
end
