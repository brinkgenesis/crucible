defmodule Crucible.Repo.Migrations.AddConstraintsAndIndexes do
  use Ecto.Migration

  def up do
    # --- Check constraints ---

    # clients: name must not be empty string
    execute "ALTER TABLE clients ADD CONSTRAINT clients_name_not_empty CHECK (name != '')"

    # cards: estimated_cost_usd must be non-negative when set
    execute """
    ALTER TABLE cards
      ADD CONSTRAINT cards_estimated_cost_usd_non_negative
      CHECK (estimated_cost_usd IS NULL OR estimated_cost_usd >= 0)
    """

    # users: email must contain @ (lenient — allows dev@localhost)
    execute """
    ALTER TABLE users
      ADD CONSTRAINT users_email_format
      CHECK (email ~* '^[^\\s]+@[^\\s]+$')
    """

    # --- Composite indexes for common query patterns ---

    # workflow_runs: filter by status ordered by time (created_at after rename migration)
    create index(:workflow_runs, [:status, :created_at],
             name: :workflow_runs_status_created_at_idx
           )

    # audit_logs already has a created_at index from the create migration;
    # add a composite (action, created_at) index for audit queries filtered by action
    create index(:audit_logs, [:action, :created_at], name: :audit_logs_action_created_at_idx)
  end

  def down do
    drop index(:audit_logs, [:action, :created_at], name: :audit_logs_action_created_at_idx)

    drop index(:workflow_runs, [:status, :created_at], name: :workflow_runs_status_created_at_idx)

    execute "ALTER TABLE users DROP CONSTRAINT IF EXISTS users_email_format"
    execute "ALTER TABLE cards DROP CONSTRAINT IF EXISTS cards_estimated_cost_usd_non_negative"
    execute "ALTER TABLE clients DROP CONSTRAINT IF EXISTS clients_name_not_empty"
  end
end
