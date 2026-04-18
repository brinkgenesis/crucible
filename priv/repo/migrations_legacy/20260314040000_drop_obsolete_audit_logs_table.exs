defmodule Crucible.Repo.Migrations.DropObsoleteAuditLogsTable do
  use Ecto.Migration

  def up do
    execute("DROP TABLE IF EXISTS audit_logs")
  end

  def down do
    execute("""
    CREATE TABLE IF NOT EXISTS audit_logs (
      id UUID PRIMARY KEY,
      user_id TEXT,
      client_id TEXT,
      action TEXT NOT NULL,
      resource TEXT,
      details JSONB NOT NULL DEFAULT '{}'::jsonb,
      ip TEXT,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("CREATE INDEX IF NOT EXISTS audit_logs_created_at_idx ON audit_logs (created_at)")
    execute("CREATE INDEX IF NOT EXISTS audit_logs_user_id_idx ON audit_logs (user_id)")
    execute("CREATE INDEX IF NOT EXISTS audit_logs_action_idx ON audit_logs (action)")

    execute(
      "CREATE INDEX IF NOT EXISTS audit_logs_action_created_at_idx ON audit_logs (action, created_at)"
    )
  end
end
