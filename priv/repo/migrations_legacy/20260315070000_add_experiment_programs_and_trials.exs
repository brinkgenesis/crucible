defmodule Crucible.Repo.Migrations.AddExperimentProgramsAndTrials do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS experiment_programs (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL REFERENCES benchmark_projects(id) ON DELETE CASCADE,
      name TEXT NOT NULL DEFAULT 'default',
      description TEXT,
      instructions_md TEXT NOT NULL DEFAULT '',
      mutable_paths TEXT[] NOT NULL DEFAULT '{}',
      readonly_paths TEXT[] NOT NULL DEFAULT '{}',
      time_budget_seconds INTEGER NOT NULL DEFAULT 300,
      max_attempts INTEGER NOT NULL DEFAULT 50,
      evaluator JSONB NOT NULL DEFAULT '{}',
      active BOOLEAN NOT NULL DEFAULT TRUE,
      version INTEGER NOT NULL DEFAULT 1,
      metadata JSONB NOT NULL DEFAULT '{}',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      UNIQUE (project_id, name)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_experiment_programs_project_active
      ON experiment_programs (project_id, active)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS experiment_trials (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL REFERENCES benchmark_projects(id) ON DELETE CASCADE,
      program_id TEXT NOT NULL REFERENCES experiment_programs(id) ON DELETE CASCADE,
      candidate_experiment_id TEXT REFERENCES experiment_runs(id) ON DELETE SET NULL,
      base_experiment_id TEXT REFERENCES experiment_runs(id) ON DELETE SET NULL,
      source_run_id TEXT REFERENCES workflow_runs(run_id) ON DELETE SET NULL,
      status TEXT NOT NULL DEFAULT 'pending'
        CHECK (
          status IN ('pending', 'running', 'evaluated', 'kept', 'discarded', 'failed', 'aborted')
        ),
      decision TEXT CHECK (decision IN ('keep', 'discard')),
      metric_name TEXT,
      metric_direction TEXT CHECK (metric_direction IN ('asc', 'desc')),
      baseline_metric NUMERIC,
      candidate_metric NUMERIC,
      reason TEXT,
      metadata JSONB NOT NULL DEFAULT '{}',
      started_at TIMESTAMPTZ,
      ended_at TIMESTAMPTZ,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_experiment_trials_project_status_created
      ON experiment_trials (project_id, status, created_at DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_experiment_trials_program_created
      ON experiment_trials (program_id, created_at DESC)
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_experiment_trials_candidate_unique
      ON experiment_trials (candidate_experiment_id)
      WHERE candidate_experiment_id IS NOT NULL
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS experiment_trials")
    execute("DROP TABLE IF EXISTS experiment_programs")
  end
end
