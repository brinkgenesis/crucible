defmodule Crucible.Repo.Migrations.AddWorkspacePathToWorkflowRuns do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE workflow_runs ADD COLUMN IF NOT EXISTS workspace_path TEXT")

    execute("""
    CREATE INDEX IF NOT EXISTS workflow_runs_workspace_path_idx
    ON workflow_runs (workspace_path)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS workflow_runs_client_workspace_created_at_idx
    ON workflow_runs (client_id, workspace_path, created_at DESC)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS workflow_runs_client_workspace_created_at_idx")
    execute("DROP INDEX IF EXISTS workflow_runs_workspace_path_idx")
    execute("ALTER TABLE workflow_runs DROP COLUMN IF EXISTS workspace_path")
  end
end
