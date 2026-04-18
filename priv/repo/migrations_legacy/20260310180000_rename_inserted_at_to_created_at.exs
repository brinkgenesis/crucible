defmodule Crucible.Repo.Migrations.RenameInsertedAtToCreatedAt do
  use Ecto.Migration

  @doc """
  Renames `inserted_at` → `created_at` across all tables for interop with
  the TypeScript dashboard, which uses `created_at` (SQL convention).

  Uses `IF EXISTS` so this is safe to run even if the column was already
  named `created_at` (e.g. if the TS migration ran first).
  """

  @tables_with_inserted_at [
    :users,
    :sessions,
    :clients,
    :client_team,
    :client_config,
    :cards,
    :workflow_runs,
    :research_projects,
    :project_metrics,
    :price_data,
    :derivatives_data,
    :social_signals,
    :anomaly_events,
    :project_scores,
    :asset_source_mappings,
    :idempotency_keys
  ]

  def up do
    for table <- @tables_with_inserted_at do
      # Use DO block to safely skip tables where column was already renamed
      execute """
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_name = '#{table}' AND column_name = 'inserted_at'
        ) THEN
          ALTER TABLE #{table} RENAME COLUMN inserted_at TO created_at;
        END IF;
      END $$;
      """
    end
  end

  def down do
    for table <- @tables_with_inserted_at do
      execute """
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_name = '#{table}' AND column_name = 'created_at'
        ) THEN
          ALTER TABLE #{table} RENAME COLUMN created_at TO inserted_at;
        END IF;
      END $$;
      """
    end
  end
end
