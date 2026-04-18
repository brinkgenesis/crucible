defmodule Crucible.Repo.Migrations.EmbedPolicyAndPr do
  use Ecto.Migration

  def up do
    # Add consolidated JSONB columns
    alter table(:workflow_runs) do
      add :policy, :jsonb
      add :pull_request, :jsonb
    end

    flush()

    # Migrate existing data into the new JSONB columns
    execute """
    UPDATE workflow_runs
    SET policy = jsonb_build_object(
      'policy_id', policy_id,
      'variant', policy_variant,
      'canary', COALESCE(policy_canary, false),
      'timings', COALESCE(policy_timings, '{}'::jsonb)
    )
    WHERE policy_id IS NOT NULL
    """

    execute """
    UPDATE workflow_runs
    SET pull_request = jsonb_build_object(
      'branch_name', pr_branch_name,
      'number', pr_number,
      'url', pr_url
    )
    WHERE pr_branch_name IS NOT NULL OR pr_number IS NOT NULL OR pr_url IS NOT NULL
    """

    # Remove the old flat columns
    alter table(:workflow_runs) do
      remove :policy_id
      remove :policy_variant
      remove :policy_canary
      remove :policy_timings
      remove :pr_branch_name
      remove :pr_number
      remove :pr_url
    end
  end

  def down do
    # Re-add flat columns
    alter table(:workflow_runs) do
      add :policy_id, :text
      add :policy_variant, :text
      add :policy_canary, :boolean
      add :policy_timings, :jsonb
      add :pr_branch_name, :text
      add :pr_number, :integer
      add :pr_url, :text
    end

    flush()

    # Migrate data back from JSONB to flat columns
    execute """
    UPDATE workflow_runs
    SET
      policy_id = policy->>'policy_id',
      policy_variant = policy->>'variant',
      policy_canary = (policy->>'canary')::boolean,
      policy_timings = (policy->'timings')::jsonb,
      pr_branch_name = pull_request->>'branch_name',
      pr_number = (pull_request->>'number')::integer,
      pr_url = pull_request->>'url'
    WHERE policy IS NOT NULL OR pull_request IS NOT NULL
    """

    # Remove JSONB columns
    alter table(:workflow_runs) do
      remove :policy
      remove :pull_request
    end
  end
end
