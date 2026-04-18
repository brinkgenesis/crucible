defmodule Crucible.Schema.User do
  @moduledoc "User account. Maps to `users` table."
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [inserted_at: :created_at]
  @primary_key {:id, :string, autogenerate: false}

  schema "users" do
    field :email, :string
    field :name, :string, default: ""
    field :picture_url, :string
    field :role, :string, default: "viewer"

    has_many :sessions, Crucible.Schema.Session

    timestamps(type: :utc_datetime)
  end

  @roles ~w(admin operator viewer)

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :picture_url, :role])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> validate_length(:email, max: 254)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:role, @roles)
    |> unique_constraint(:email)
  end
end
