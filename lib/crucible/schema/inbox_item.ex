defmodule Crucible.Schema.InboxItem do
  @moduledoc "Inbox item from an ingestion source. Maps to `inbox_items` table."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @sources ~w(link rss github webhook manual run_failure)
  @statuses ~w(unread read actioned dismissed)

  schema "inbox_items" do
    field(:source, :string, default: "link")
    field(:source_id, :string)
    field(:status, :string, default: "unread")
    field(:title, :string)
    field(:author, :string)
    field(:original_text, :string, default: "")
    field(:summary, :string)
    field(:extracted_urls, {:array, :string}, default: [])
    field(:extracted_repos, {:array, :string}, default: [])
    field(:eval_result, :map)
    field(:card_id, :string)
    field(:metadata, :map, default: %{})
    field(:ingested_at, :utc_datetime)

    timestamps()
  end

  @required ~w(source source_id)a
  @optional ~w(status title author original_text summary extracted_urls extracted_repos
               eval_result card_id metadata ingested_at)a

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(item, attrs) do
    item
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:source, :source_id])
  end
end
