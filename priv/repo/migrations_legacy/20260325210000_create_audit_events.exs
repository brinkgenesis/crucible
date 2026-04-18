defmodule Crucible.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def change do
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
