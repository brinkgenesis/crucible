defmodule Crucible.Schema.AuditEvent do
  @moduledoc """
  Append-only audit log for entity mutations. Maps to the `audit_events` table.

  Each record captures a single mutation to a domain entity (policy, budget,
  workflow, client, etc.) with the following fields:

  * `entity_type` — the kind of entity being mutated (e.g. `"policy"`, `"budget"`)
  * `entity_id`   — the primary key of the mutated entity
  * `event_type`  — what happened (e.g. `"created"`, `"updated"`, `"deleted"`)
  * `actor`       — who or what triggered the change (user ID, system process, etc.)
  * `payload`     — arbitrary map of before/after values or extra context
  * `occurred_at` — when the real-world event happened (defaults to insert time)

  Records are created via `Crucible.AuditTrail.record/1` and are
  intentionally immutable — `updated_at` is disabled on the schema.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "audit_events" do
    field :entity_type, :string
    field :entity_id, :string
    field :event_type, :string
    field :actor, :string
    field :payload, :map, default: %{}
    field :occurred_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @required ~w(entity_type entity_id event_type)a
  @optional ~w(actor payload occurred_at)a

  @type t :: %__MODULE__{}

  @doc """
  Builds a changeset for an audit event.

  Requires `entity_type`, `entity_id`, and `event_type`. Optionally accepts
  `actor`, `payload`, and `occurred_at`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
  end
end
