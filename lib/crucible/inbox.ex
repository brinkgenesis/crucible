defmodule Crucible.Inbox do
  @moduledoc """
  Inbox operations — thin facade over the inbox pipeline modules.

  See `Crucible.Inbox.Scanner` for the full scan pipeline and
  `Crucible.Schema.InboxItem` for the schema.
  """

  import Ecto.Query

  alias Crucible.Repo
  alias Crucible.Schema.InboxItem

  @doc "Return recent inbox items, ordered by ingested_at desc."
  def recent_items(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    status = Keyword.get(opts, :status)

    query = InboxItem |> order_by([i], desc: i.ingested_at) |> limit(^limit)
    query = if status, do: where(query, [i], i.status == ^status), else: query
    Repo.all(query)
  end

  @upsert_fields ~w(status title author original_text summary extracted_urls
                     extracted_repos eval_result card_id metadata ingested_at updated_at)a

  @doc "Upsert an inbox item from an ingestion source. Atomic — no TOCTOU race."
  def upsert_from_ingestion(attrs) when is_map(attrs) do
    %InboxItem{}
    |> InboxItem.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, @upsert_fields},
      conflict_target: [:source, :source_id],
      returning: true
    )
  end
end
