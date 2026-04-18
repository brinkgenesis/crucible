defmodule Crucible.Repo.Migrations.CreateAuditLogs do
  use Ecto.Migration

  def change do
    create table(:audit_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :text
      add :client_id, :text
      add :action, :text, null: false
      add :resource, :text
      add :details, :jsonb, null: false, default: "{}"
      add :ip, :text
      add :created_at, :timestamptz, null: false, default: fragment("NOW()")
    end

    create index(:audit_logs, [:created_at])
    create index(:audit_logs, [:user_id])
    create index(:audit_logs, [:action])
  end
end
