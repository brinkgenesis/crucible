defmodule Crucible.Repo.Migrations.AddPoliciesAndRunMetadata do
  use Ecto.Migration

  def change do
    # Policy fields on workspaces
    alter table(:workspaces) do
      add :allowed_models, {:array, :text}, default: []
      add :cost_limit_usd, :decimal
      add :approval_threshold, :integer
    end

    # Enrichment fields on workflow_runs
    alter table(:workflow_runs) do
      add :trigger_source, :text
      add :primary_model, :text
    end
  end
end
