defmodule Crucible.Schema.CardEvent do
  @moduledoc "Append-only audit log for card changes. Maps to `card_events` table."
  use Ecto.Schema
  import Ecto.Changeset

  schema "card_events" do
    field :card_id, :string
    field :event_type, :string
    field :occurred_at, :utc_datetime
    field :actor, :string
    field :payload, :map, default: %{}
  end

  @required ~w(card_id event_type)a
  @optional ~w(occurred_at actor payload)a

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
  end
end
