defmodule Crucible.Repo.Migrations.AddBenchmarkPublicationTables do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS benchmark_projects (
      id TEXT PRIMARY KEY,
      slug TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      description TEXT,
      domain TEXT NOT NULL,
      metric_name TEXT NOT NULL,
      metric_direction TEXT NOT NULL CHECK (metric_direction IN ('asc', 'desc')),
      metric_unit TEXT,
      source_kind TEXT NOT NULL DEFAULT 'workflow',
      status TEXT NOT NULL DEFAULT 'active',
      is_public BOOLEAN NOT NULL DEFAULT FALSE,
      metadata JSONB NOT NULL DEFAULT '{}',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute(
      "CREATE INDEX IF NOT EXISTS idx_benchmark_projects_domain ON benchmark_projects (domain)"
    )

    execute("""
    CREATE INDEX IF NOT EXISTS idx_benchmark_projects_public_status
      ON benchmark_projects (is_public, status)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS benchmark_baselines (
      id BIGSERIAL PRIMARY KEY,
      project_id TEXT NOT NULL REFERENCES benchmark_projects(id) ON DELETE CASCADE,
      version INTEGER NOT NULL DEFAULT 1,
      label TEXT NOT NULL DEFAULT 'baseline',
      config JSONB NOT NULL DEFAULT '{}',
      config_format TEXT NOT NULL DEFAULT 'json',
      result JSONB NOT NULL DEFAULT '{}',
      metric_value NUMERIC,
      duration_ms BIGINT,
      tokens_input BIGINT,
      tokens_output BIGINT,
      tokens_total BIGINT,
      cost_usd NUMERIC(12, 6),
      recorded_at TIMESTAMPTZ NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      UNIQUE (project_id, version)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_benchmark_baselines_project_recorded_at
      ON benchmark_baselines (project_id, recorded_at DESC)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS benchmark_agents (
      id TEXT PRIMARY KEY,
      display_name TEXT,
      source TEXT NOT NULL DEFAULT 'internal',
      kind TEXT NOT NULL DEFAULT 'agent',
      peer_ref TEXT,
      metadata JSONB NOT NULL DEFAULT '{}',
      first_seen_at TIMESTAMPTZ,
      last_seen_at TIMESTAMPTZ,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_benchmark_agents_source_kind
      ON benchmark_agents (source, kind)
    """)

    execute(
      "CREATE INDEX IF NOT EXISTS idx_benchmark_agents_peer_ref ON benchmark_agents (peer_ref)"
    )

    execute("""
    CREATE TABLE IF NOT EXISTS experiment_runs (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL REFERENCES benchmark_projects(id) ON DELETE CASCADE,
      agent_id TEXT REFERENCES benchmark_agents(id) ON DELETE SET NULL,
      source_run_id TEXT REFERENCES workflow_runs(run_id) ON DELETE SET NULL,
      source_type TEXT NOT NULL DEFAULT 'workflow_run',
      project_run_number INTEGER,
      agent_run_number INTEGER,
      status TEXT NOT NULL DEFAULT 'completed',
      hypothesis TEXT,
      summary TEXT,
      config JSONB NOT NULL DEFAULT '{}',
      config_format TEXT NOT NULL DEFAULT 'json',
      result JSONB NOT NULL DEFAULT '{}',
      metric_value NUMERIC,
      metric_payload JSONB NOT NULL DEFAULT '{}',
      improvement_vs_baseline NUMERIC,
      is_new_best BOOLEAN NOT NULL DEFAULT FALSE,
      hardware JSONB NOT NULL DEFAULT '{}',
      tokens_input BIGINT,
      tokens_output BIGINT,
      tokens_total BIGINT,
      cost_usd NUMERIC(12, 6),
      duration_ms BIGINT,
      started_at TIMESTAMPTZ,
      ended_at TIMESTAMPTZ,
      inspired_by_experiment_id TEXT REFERENCES experiment_runs(id) ON DELETE SET NULL,
      notes TEXT,
      published_at TIMESTAMPTZ,
      metadata JSONB NOT NULL DEFAULT '{}',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_experiment_runs_project_status
      ON experiment_runs (project_id, status)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_experiment_runs_project_ended_at
      ON experiment_runs (project_id, ended_at DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_experiment_runs_project_metric
      ON experiment_runs (project_id, metric_value)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_experiment_runs_agent_created_at
      ON experiment_runs (agent_id, created_at DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_experiment_runs_new_best
      ON experiment_runs (project_id, is_new_best)
      WHERE is_new_best = TRUE
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_experiment_runs_source_run_id_unique
      ON experiment_runs (source_run_id)
      WHERE source_run_id IS NOT NULL
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_experiment_runs_project_run_number_unique
      ON experiment_runs (project_id, project_run_number)
      WHERE project_run_number IS NOT NULL
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_experiment_runs_agent_run_number_unique
      ON experiment_runs (agent_id, agent_run_number)
      WHERE agent_id IS NOT NULL AND agent_run_number IS NOT NULL
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS experiment_artifacts (
      id BIGSERIAL PRIMARY KEY,
      experiment_id TEXT NOT NULL REFERENCES experiment_runs(id) ON DELETE CASCADE,
      artifact_type TEXT NOT NULL,
      storage_kind TEXT NOT NULL DEFAULT 'inline',
      mime_type TEXT,
      path TEXT,
      content_text TEXT,
      content_json JSONB,
      sha256 TEXT,
      metadata JSONB NOT NULL DEFAULT '{}',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_experiment_artifacts_lookup
      ON experiment_artifacts (experiment_id, artifact_type)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS leaderboard_snapshots (
      id TEXT PRIMARY KEY,
      project_id TEXT REFERENCES benchmark_projects(id) ON DELETE CASCADE,
      agent_id TEXT REFERENCES benchmark_agents(id) ON DELETE CASCADE,
      scope TEXT NOT NULL CHECK (scope IN ('global', 'project', 'agent')),
      generated_at TIMESTAMPTZ NOT NULL,
      version INTEGER NOT NULL DEFAULT 1,
      summary TEXT,
      payload JSONB NOT NULL DEFAULT '{}',
      artifact_path TEXT,
      source TEXT NOT NULL DEFAULT 'publisher',
      commit_sha TEXT,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_leaderboard_snapshots_scope_generated_at
      ON leaderboard_snapshots (scope, generated_at DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_leaderboard_snapshots_project_generated_at
      ON leaderboard_snapshots (project_id, generated_at DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_leaderboard_snapshots_agent_generated_at
      ON leaderboard_snapshots (agent_id, generated_at DESC)
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS leaderboard_snapshots")
    execute("DROP TABLE IF EXISTS experiment_artifacts")
    execute("DROP TABLE IF EXISTS experiment_runs")
    execute("DROP TABLE IF EXISTS benchmark_agents")
    execute("DROP TABLE IF EXISTS benchmark_baselines")
    execute("DROP TABLE IF EXISTS benchmark_projects")
  end
end
