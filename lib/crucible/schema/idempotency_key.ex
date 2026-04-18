defmodule Crucible.Schema.IdempotencyKey do
  @moduledoc "Request deduplication. Maps to `idempotency_keys` table."
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [inserted_at: :created_at]
  @primary_key false

  schema "idempotency_keys" do
    field :scope, :string, primary_key: true
    field :key, :string, primary_key: true
    field :request_hash, :string
    field :status_code, :integer
    field :response, :map
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(idem, attrs) do
    idem
    |> cast(attrs, [:scope, :key, :request_hash, :status_code, :response, :expires_at])
    |> validate_required([:scope, :key, :request_hash, :status_code, :response, :expires_at])
  end
end
