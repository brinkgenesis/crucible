defmodule Crucible.Repo.Migrations.RepairPhasePersistenceColumns do
  use Ecto.Migration

  @doc """
  Repair migration: 20260317100000 is marked 'up' in schema_migrations but its
  DDL was never applied (columns missing from workflow_runs, tables
  conversation_history and agent_jobs absent). This migration adds the missing
  objects idempotently using IF NOT EXISTS guards.
  """

  def up do
    # --- workflow_runs: add missing phase-persistence columns ---
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'workflow_runs' AND column_name = 'current_phase_index'
      ) THEN
        ALTER TABLE workflow_runs ADD COLUMN current_phase_index integer;
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'workflow_runs' AND column_name = 'current_phase_status'
      ) THEN
        ALTER TABLE workflow_runs ADD COLUMN current_phase_status text;
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'workflow_runs' AND column_name = 'active_node'
      ) THEN
        ALTER TABLE workflow_runs ADD COLUMN active_node text;
      END IF;
    END
    $$;
    """

    # --- conversation_history table ---
    execute """
    CREATE TABLE IF NOT EXISTS conversation_history (
      id bigserial PRIMARY KEY,
      run_id text NOT NULL,
      phase_index integer NOT NULL,
      turn_number integer NOT NULL,
      role text NOT NULL,
      content text,
      token_count integer DEFAULT 0,
      is_summary boolean DEFAULT false,
      inserted_at timestamp(0) without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      updated_at timestamp(0) without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
    );
    """

    execute """
    CREATE INDEX IF NOT EXISTS conversation_history_run_id_phase_index_index
      ON conversation_history (run_id, phase_index);
    """

    # --- agent_jobs table ---
    execute """
    CREATE TABLE IF NOT EXISTS agent_jobs (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      run_id text,
      parent_phase text,
      config jsonb NOT NULL DEFAULT '{}',
      status text NOT NULL DEFAULT 'pending',
      result jsonb,
      error text,
      launched_at timestamp(0) without time zone,
      completed_at timestamp(0) without time zone,
      inserted_at timestamp(0) without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      updated_at timestamp(0) without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
    );
    """

    execute "CREATE INDEX IF NOT EXISTS agent_jobs_status_index ON agent_jobs (status);"
    execute "CREATE INDEX IF NOT EXISTS agent_jobs_run_id_index ON agent_jobs (run_id);"
  end

  def down do
    execute "DROP TABLE IF EXISTS agent_jobs;"
    execute "DROP TABLE IF EXISTS conversation_history;"

    alter table(:workflow_runs) do
      remove_if_exists :current_phase_index, :integer
      remove_if_exists :current_phase_status, :text
      remove_if_exists :active_node, :text
    end
  end
end
