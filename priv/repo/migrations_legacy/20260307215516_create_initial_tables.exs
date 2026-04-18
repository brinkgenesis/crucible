defmodule Crucible.Repo.Migrations.CreateInitialTables do
  use Ecto.Migration

  def change do
    # --- Clients & Auth ---

    create table(:clients, primary_key: false) do
      add :id, :text, primary_key: true
      add :name, :text, null: false
      add :slug, :text, null: false
      add :industry, :text
      add :tier, :text, null: false, default: "build"
      timestamps(type: :timestamptz)
    end

    create unique_index(:clients, [:slug])

    create table(:users, primary_key: false) do
      add :id, :text, primary_key: true
      add :email, :text, null: false
      add :name, :text, null: false, default: ""
      add :picture_url, :text
      add :role, :text, null: false, default: "analyst"
      timestamps(type: :timestamptz)
    end

    create unique_index(:users, [:email])

    create table(:sessions, primary_key: false) do
      add :id, :text, primary_key: true
      add :user_id, references(:users, type: :text, on_delete: :delete_all), null: false
      add :expires_at, :timestamptz, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("NOW()")
    end

    create index(:sessions, [:user_id])
    create index(:sessions, [:expires_at])

    create table(:client_team, primary_key: false) do
      add :client_id, references(:clients, type: :text, on_delete: :delete_all), primary_key: true
      add :user_id, references(:users, type: :text, on_delete: :delete_all), primary_key: true
      add :role, :text, null: false
      add :is_lead, :boolean, null: false, default: false
      add :inserted_at, :timestamptz, null: false, default: fragment("NOW()")
    end

    create index(:client_team, [:user_id])

    create table(:client_config, primary_key: false) do
      add :client_id, references(:clients, type: :text, on_delete: :delete_all), primary_key: true
      add :accounting_system, :text
      add :fiscal_year_end, :text
      add :close_deadline_day, :integer
      add :budget_limit_usd, :numeric
      add :vault_prefix, :text
      timestamps(type: :timestamptz)
    end

    # --- Kanban & Workflow ---

    create table(:cards, primary_key: false) do
      add :id, :text, primary_key: true
      add :title, :text, null: false
      add :column, :text, null: false
      add :version, :integer, null: false, default: 0
      add :archived, :boolean, null: false, default: false
      add :archived_at, :timestamptz
      add :workflow, :text
      add :run_id, :text
      add :estimated_cost_usd, :numeric, precision: 10, scale: 4
      add :agent_role, :text
      add :phase_name, :text
      add :spawned_at, :timestamptz
      add :pid, :integer
      add :parent_card_id, references(:cards, type: :text, on_delete: :delete_all)
      add :phase_cards, :jsonb
      add :phase_depends_on, :jsonb
      add :metadata, :jsonb
      add :client_id, references(:clients, type: :text, on_delete: :nilify_all)
      timestamps(type: :timestamptz)
    end

    create index(:cards, [:archived, :updated_at], name: :cards_active_idx)
    create index(:cards, [:parent_card_id])
    create index(:cards, [:column])
    create index(:cards, [:client_id])

    create table(:card_events) do
      add :card_id, :text, null: false
      add :event_type, :text, null: false
      add :occurred_at, :timestamptz, null: false, default: fragment("NOW()")
      add :actor, :text
      add :payload, :jsonb, null: false, default: "{}"
    end

    create index(:card_events, [:card_id, :occurred_at], name: :card_events_card_id_idx)
    create index(:card_events, [:occurred_at])

    create table(:workflow_runs, primary_key: false) do
      add :run_id, :text, primary_key: true
      add :card_id, :text
      add :workflow_name, :text, null: false
      add :task_description, :text, null: false
      add :version, :integer, null: false, default: 0
      add :status, :text, null: false, default: "pending"
      add :execution_type, :text, null: false, default: "subscription"
      add :phases, :jsonb, null: false, default: "[]"
      add :plan_note, :text
      add :plan_summary, :text
      add :complexity, :integer
      add :base_commit, :text
      add :session_resume_chain, :jsonb
      add :last_transition_key, :text
      add :retry_count, :integer, null: false, default: 0
      add :max_retries, :integer
      add :policy_id, :text
      add :policy_variant, :text
      add :policy_canary, :boolean
      add :policy_timings, :jsonb
      add :pr_branch_name, :text
      add :pr_number, :integer
      add :pr_url, :text
      add :client_id, references(:clients, type: :text, on_delete: :nilify_all)
      timestamps(type: :timestamptz)
    end

    create index(:workflow_runs, [:status])
    create index(:workflow_runs, [:card_id])
    create index(:workflow_runs, [:inserted_at])
    create index(:workflow_runs, [:client_id])

    create table(:trace_events) do
      add :timestamp, :timestamptz, null: false
      add :trace_id, :text, null: false
      add :run_id, :text
      add :phase_id, :text
      add :agent_id, :text
      add :session_id, :text
      add :event_type, :text, null: false
      add :tool, :text
      add :detail, :text
      add :metadata, :jsonb, null: false, default: "{}"
      add :client_id, references(:clients, type: :text, on_delete: :nilify_all)
    end

    create index(:trace_events, [:run_id])
    create index(:trace_events, [:event_type])
    create index(:trace_events, [:timestamp])
    create index(:trace_events, [:client_id])

    # --- Idempotency ---

    create table(:idempotency_keys, primary_key: false) do
      add :scope, :text, primary_key: true
      add :key, :text, primary_key: true
      add :request_hash, :text, null: false
      add :status_code, :integer, null: false
      add :response, :jsonb, null: false
      add :expires_at, :timestamptz, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("NOW()")
    end

    create index(:idempotency_keys, [:expires_at])

    # --- Research ---

    create table(:research_projects, primary_key: false) do
      add :id, :text, primary_key: true
      add :name, :text, null: false
      add :ticker, :text
      add :category, :text
      add :chain, :text
      add :coingecko_id, :text
      add :defillama_id, :text
      add :github_org, :text
      add :twitter_handle, :text
      add :allium_schema, :text
      add :metadata, :jsonb, null: false, default: "{}"
      add :active, :boolean, null: false, default: true
      timestamps(type: :timestamptz)
    end

    create index(:research_projects, [:active],
             where: "active = TRUE",
             name: :idx_research_projects_active
           )

    create index(:research_projects, [:category])

    create table(:project_metrics) do
      add :project_id, references(:research_projects, type: :text), null: false
      add :metric_type, :text, null: false
      add :value, :numeric, null: false
      add :unit, :text, null: false, default: "usd"
      add :source, :text, null: false
      add :snapshot_at, :timestamptz, null: false
      add :metadata, :jsonb, null: false, default: "{}"
      add :inserted_at, :timestamptz, null: false, default: fragment("NOW()")
    end

    create index(:project_metrics, [:project_id, :metric_type])
    create index(:project_metrics, [:snapshot_at])

    create table(:price_data) do
      add :project_id, references(:research_projects, type: :text), null: false
      add :price_usd, :numeric, null: false
      add :volume_24h, :numeric
      add :mcap, :numeric
      add :price_change_pct_24h, :numeric
      add :source, :text, null: false, default: "coingecko"
      add :snapshot_at, :timestamptz, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("NOW()")
    end

    create index(:price_data, [:project_id, :snapshot_at])

    create table(:derivatives_data) do
      add :project_id, references(:research_projects, type: :text), null: false
      add :exchange, :text, null: false
      add :oi_usd, :numeric
      add :funding_rate, :numeric
      add :cvd, :numeric
      add :long_short_ratio, :numeric
      add :liquidations_24h, :numeric
      add :snapshot_at, :timestamptz, null: false
      add :metadata, :jsonb, null: false, default: "{}"
      add :inserted_at, :timestamptz, null: false, default: fragment("NOW()")
    end

    create index(:derivatives_data, [:project_id, :snapshot_at])

    create table(:social_signals) do
      add :project_id, references(:research_projects, type: :text), null: false
      add :signal_type, :text, null: false
      add :source_url, :text
      add :author, :text
      add :author_tier, :text
      add :content, :text
      add :sentiment, :text
      add :severity, :text, null: false, default: "info"
      add :raw_data, :jsonb, null: false, default: "{}"
      add :observed_at, :timestamptz, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("NOW()")
    end

    create index(:social_signals, [:project_id, :observed_at])
    create index(:social_signals, [:signal_type])

    create table(:anomaly_events) do
      add :project_id, references(:research_projects, type: :text), null: false
      add :anomaly_type, :text, null: false
      add :metric_type, :text
      add :current_value, :numeric
      add :baseline_value, :numeric
      add :std_dev, :numeric
      add :z_score, :numeric
      add :direction, :text
      add :severity, :text, null: false
      add :description, :text
      add :resolved, :boolean, null: false, default: false
      add :observed_at, :timestamptz, null: false
      add :metadata, :jsonb, null: false, default: "{}"
      add :inserted_at, :timestamptz, null: false, default: fragment("NOW()")
    end

    create index(:anomaly_events, [:project_id, :observed_at])

    create index(:anomaly_events, [:resolved],
             where: "resolved = FALSE",
             name: :idx_anomaly_events_unresolved
           )

    create index(:anomaly_events, [:severity])

    create table(:project_scores) do
      add :project_id, references(:research_projects, type: :text), null: false
      add :score_version, :integer, null: false, default: 1
      add :fundamentals, :jsonb, null: false, default: "{}"
      add :momentum, :jsonb, null: false, default: "{}"
      add :derivatives, :jsonb, null: false, default: "{}"
      add :social, :jsonb, null: false, default: "{}"
      add :development, :jsonb, null: false, default: "{}"
      add :risk, :jsonb, null: false, default: "{}"
      add :weights, :jsonb, null: false
      add :composite_score, :numeric, null: false
      add :confidence, :numeric, null: false
      add :analyst_notes, :text
      add :scored_at, :timestamptz, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("NOW()")
    end

    create index(:project_scores, [:project_id, :scored_at])

    create table(:source_scores) do
      add :source_name, :text, null: false
      add :reliability, :numeric, null: false, default: 0.8
      add :latency_avg_ms, :integer
      add :last_success, :timestamptz
      add :last_failure, :timestamptz
      add :failure_count, :integer, null: false, default: 0
      add :total_calls, :integer, null: false, default: 0
      add :metadata, :jsonb, null: false, default: "{}"
      add :updated_at, :timestamptz, null: false, default: fragment("NOW()")
    end

    create unique_index(:source_scores, [:source_name])

    create table(:asset_source_mappings) do
      add :query, :text, null: false
      add :source, :text, null: false
      add :source_id, :text, null: false
      add :source_name, :text, null: false
      add :symbol, :text
      add :category, :text
      add :chains, :jsonb, default: "[]"
      add :market_cap_rank, :integer
      add :tvl, :numeric
      add :thumb_url, :text
      add :github_org, :text
      add :twitter_handle, :text
      add :metadata, :jsonb, null: false, default: "{}"
      add :fetched_at, :timestamptz, null: false, default: fragment("NOW()")
      add :inserted_at, :timestamptz, null: false, default: fragment("NOW()")
    end

    create index(:asset_source_mappings, [:query, :source])

    create unique_index(:asset_source_mappings, [:query, :source, :source_id],
             name: :idx_asm_dedup
           )
  end
end
