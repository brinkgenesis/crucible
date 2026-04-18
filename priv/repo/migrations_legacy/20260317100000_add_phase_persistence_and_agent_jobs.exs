defmodule Crucible.Repo.Migrations.AddPhasePersistenceAndAgentJobs do
  use Ecto.Migration

  def change do
    # Phase persistence: track which phase is active so crashed runs can resume
    alter table(:workflow_runs) do
      add :current_phase_index, :integer
      add :current_phase_status, :text
      add :active_node, :text
    end

    # Conversation history for context window management (P2)
    create table(:conversation_history) do
      add :run_id, :text, null: false
      add :phase_index, :integer, null: false
      add :turn_number, :integer, null: false
      add :role, :text, null: false
      add :content, :text
      add :token_count, :integer, default: 0
      add :is_summary, :boolean, default: false

      timestamps(type: :utc_datetime)
    end

    create index(:conversation_history, [:run_id, :phase_index])

    # Agent jobs for async agent API (P3)
    create table(:agent_jobs, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :run_id, :text
      add :parent_phase, :text
      add :config, :jsonb, null: false, default: "{}"
      add :status, :text, null: false, default: "pending"
      add :result, :jsonb
      add :error, :text
      add :launched_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:agent_jobs, [:status])
    create index(:agent_jobs, [:run_id])
  end
end
