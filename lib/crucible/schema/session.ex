defmodule Crucible.Schema.Session do
  @moduledoc "OAuth2 browser session. Maps to `sessions` table."
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [inserted_at: :created_at]
  @primary_key {:id, :string, autogenerate: false}

  schema "sessions" do
    field :expires_at, :utc_datetime

    belongs_to :user, Crucible.Schema.User, type: :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> cast(attrs, [:user_id, :expires_at])
    |> validate_required([:user_id, :expires_at])
    |> foreign_key_constraint(:user_id)
  end
end
