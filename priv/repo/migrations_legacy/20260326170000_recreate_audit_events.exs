defmodule Crucible.Repo.Migrations.RecreateAuditEvents do
  use Ecto.Migration

  @doc """
  The audit_events table was pre-created with a stale schema (timestamp, action,
  resource_type, etc.) before migration 20260325210000 ran. That migration's
  `create table` was silently skipped because the table already existed, leaving
  the DB out of sync with the Ecto schema. Drop and recreate with correct columns.
  """

  def change do
    drop_if_exists table(:audit_events)

    create table(:audit_events) do
      add :entity_type, :text, null: false
      add :entity_id, :text, null: false
      add :event_type, :text, null: false
      add :actor, :text
      add :payload, :jsonb, default: "{}"
      add :occurred_at, :utc_datetime, null: false, default: fragment("NOW()")

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:audit_events, [:entity_type, :entity_id, :occurred_at])
    create index(:audit_events, [:occurred_at])
  end
end
