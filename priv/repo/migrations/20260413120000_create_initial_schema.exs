defmodule Crucible.Repo.Migrations.CreateInitialSchema do
  @moduledoc """
  Single consolidated initial schema for Crucible v0.

  Replaces 22 historical migrations that accumulated during the upstream
  infra-orchestrator port. Tables that backed personal/internal features
  (clients, inbox, benchmarks, experiments, research) were dropped during
  the port and are NOT recreated here.

  If you need to re-derive any of the legacy DDL, the original migrations
  are preserved under `priv/repo/migrations_legacy/`.
  """
  use Ecto.Migration

  def up do
    execute """
    CREATE TYPE oban_job_state AS ENUM (
      'available', 'scheduled', 'executing', 'retryable',
      'completed', 'discarded', 'cancelled'
    )
    """

    # ── Core: workspaces, cards, runs ────────────────────────────────────────
    execute """
    CREATE TABLE workspaces (
      id text PRIMARY KEY,
      name text NOT NULL,
      slug text NOT NULL,
      repo_path text NOT NULL,
      tech_context text NOT NULL DEFAULT '',
      default_workflow text NOT NULL DEFAULT 'coding-sprint',
      default_branch varchar(255) DEFAULT 'main',
      allowed_models text[] DEFAULT ARRAY[]::text[],
      cost_limit_usd numeric,
      approval_threshold integer,
      created_at timestamp(0) without time zone NOT NULL,
      updated_at timestamp(0) without time zone NOT NULL
    )
    """

    execute "CREATE UNIQUE INDEX workspaces_slug_index ON workspaces (slug)"

    execute """
    CREATE TABLE cards (
      id text PRIMARY KEY,
      title text NOT NULL,
      "column" text NOT NULL,
      version integer NOT NULL DEFAULT 0,
      archived boolean NOT NULL DEFAULT false,
      archived_at timestamp with time zone,
      workflow text,
      run_id text,
      estimated_cost_usd numeric(10,4),
      agent_role text,
      phase_name text,
      spawned_at timestamp with time zone,
      pid integer,
      parent_card_id text REFERENCES cards(id) ON DELETE CASCADE,
      phase_cards jsonb,
      phase_depends_on jsonb,
      metadata jsonb,
      client_id text,
      workspace_id text REFERENCES workspaces(id) ON DELETE SET NULL,
      created_at timestamp with time zone NOT NULL,
      updated_at timestamp with time zone NOT NULL,
      CONSTRAINT cards_estimated_cost_usd_non_negative
        CHECK (estimated_cost_usd IS NULL OR estimated_cost_usd >= 0)
    )
    """

    execute "CREATE INDEX cards_active_idx ON cards (archived, updated_at)"
    execute "CREATE INDEX cards_client_id_index ON cards (client_id)"
    execute ~s|CREATE INDEX cards_column_index ON cards ("column")|
    execute "CREATE INDEX cards_parent_card_id_index ON cards (parent_card_id)"
    execute "CREATE INDEX cards_workspace_id_index ON cards (workspace_id)"

    execute """
    CREATE TABLE card_events (
      id bigserial PRIMARY KEY,
      card_id text NOT NULL,
      event_type text NOT NULL,
      occurred_at timestamp with time zone NOT NULL DEFAULT now(),
      actor text,
      payload jsonb NOT NULL DEFAULT '{}'::jsonb
    )
    """

    execute "CREATE INDEX card_events_card_id_idx ON card_events (card_id, occurred_at)"
    execute "CREATE INDEX card_events_occurred_at_index ON card_events (occurred_at)"

    execute """
    CREATE TABLE workflow_runs (
      run_id text PRIMARY KEY,
      card_id text,
      workflow_name text NOT NULL,
      task_description text NOT NULL,
      version integer NOT NULL DEFAULT 0,
      status text NOT NULL DEFAULT 'pending',
      execution_type text NOT NULL DEFAULT 'subscription',
      phases jsonb NOT NULL DEFAULT '[]'::jsonb,
      plan_note text,
      plan_summary text,
      complexity integer,
      base_commit text,
      session_resume_chain jsonb,
      last_transition_key text,
      retry_count integer NOT NULL DEFAULT 0,
      max_retries integer,
      client_id text,
      workspace_path text,
      current_phase_index integer,
      current_phase_status text,
      active_node text,
      trigger_source text,
      primary_model text,
      policy jsonb,
      pull_request jsonb,
      created_at timestamp with time zone NOT NULL,
      updated_at timestamp with time zone NOT NULL
    )
    """

    execute "CREATE INDEX workflow_runs_card_id_index ON workflow_runs (card_id)"
    execute "CREATE INDEX workflow_runs_client_id_index ON workflow_runs (client_id)"
    execute "CREATE INDEX workflow_runs_status_index ON workflow_runs (status)"
    execute "CREATE INDEX workflow_runs_status_created_at_idx ON workflow_runs (status, created_at)"
    execute "CREATE INDEX workflow_runs_inserted_at_index ON workflow_runs (created_at)"
    execute "CREATE INDEX workflow_runs_workspace_path_idx ON workflow_runs (workspace_path)"
    execute "CREATE INDEX workflow_runs_client_workspace_created_at_idx ON workflow_runs (client_id, workspace_path, created_at DESC)"

    # ── Observability ────────────────────────────────────────────────────────
    execute """
    CREATE TABLE trace_events (
      id bigserial PRIMARY KEY,
      timestamp timestamp with time zone NOT NULL,
      trace_id text NOT NULL,
      run_id text,
      phase_id text,
      agent_id text,
      session_id text,
      event_type text NOT NULL,
      tool text,
      detail text,
      metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      client_id text
    )
    """

    execute "CREATE INDEX trace_events_run_id_index ON trace_events (run_id)"
    execute "CREATE INDEX trace_events_event_type_index ON trace_events (event_type)"
    execute "CREATE INDEX trace_events_timestamp_index ON trace_events (timestamp)"
    execute "CREATE INDEX trace_events_client_id_index ON trace_events (client_id)"

    execute """
    CREATE TABLE conversation_history (
      id bigserial PRIMARY KEY,
      run_id text NOT NULL,
      phase_index integer NOT NULL,
      turn_number integer NOT NULL,
      role text NOT NULL,
      content text,
      token_count integer DEFAULT 0,
      is_summary boolean DEFAULT false,
      inserted_at timestamp(0) without time zone NOT NULL,
      updated_at timestamp(0) without time zone NOT NULL
    )
    """

    execute "CREATE INDEX conversation_history_run_id_phase_index_index ON conversation_history (run_id, phase_index)"

    execute """
    CREATE TABLE audit_events (
      id bigserial PRIMARY KEY,
      entity_type text NOT NULL,
      entity_id text NOT NULL,
      event_type text NOT NULL,
      actor text,
      payload jsonb DEFAULT '{}'::jsonb,
      occurred_at timestamp(0) without time zone NOT NULL DEFAULT now(),
      inserted_at timestamp(0) without time zone NOT NULL
    )
    """

    execute "CREATE INDEX audit_events_entity_type_entity_id_occurred_at_index ON audit_events (entity_type, entity_id, occurred_at)"
    execute "CREATE INDEX audit_events_occurred_at_index ON audit_events (occurred_at)"

    # ── Auth ────────────────────────────────────────────────────────────────
    execute """
    CREATE TABLE users (
      id text PRIMARY KEY,
      email text NOT NULL,
      name text NOT NULL DEFAULT '',
      picture_url text,
      role text NOT NULL DEFAULT 'analyst',
      created_at timestamp with time zone NOT NULL,
      updated_at timestamp with time zone NOT NULL,
      CONSTRAINT users_email_format CHECK (email ~* '^[^\\s]+@[^\\s]+$')
    )
    """

    execute "CREATE UNIQUE INDEX users_email_index ON users (email)"

    execute """
    CREATE TABLE sessions (
      id text PRIMARY KEY,
      user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      expires_at timestamp with time zone NOT NULL,
      created_at timestamp with time zone NOT NULL DEFAULT now()
    )
    """

    execute "CREATE INDEX sessions_user_id_index ON sessions (user_id)"
    execute "CREATE INDEX sessions_expires_at_index ON sessions (expires_at)"

    # ── Agent jobs / idempotency ─────────────────────────────────────────────
    execute """
    CREATE TABLE agent_jobs (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      run_id text,
      parent_phase text,
      config jsonb NOT NULL DEFAULT '{}'::jsonb,
      status text NOT NULL DEFAULT 'pending',
      result jsonb,
      error text,
      launched_at timestamp(0) without time zone,
      completed_at timestamp(0) without time zone,
      inserted_at timestamp(0) without time zone NOT NULL,
      updated_at timestamp(0) without time zone NOT NULL
    )
    """

    execute "CREATE INDEX agent_jobs_run_id_index ON agent_jobs (run_id)"
    execute "CREATE INDEX agent_jobs_status_index ON agent_jobs (status)"

    execute """
    CREATE TABLE idempotency_keys (
      scope text NOT NULL,
      key text NOT NULL,
      request_hash text NOT NULL,
      status_code integer NOT NULL,
      response jsonb NOT NULL,
      expires_at timestamp with time zone NOT NULL,
      created_at timestamp with time zone NOT NULL DEFAULT now(),
      PRIMARY KEY (scope, key)
    )
    """

    execute "CREATE INDEX idempotency_keys_expires_at_index ON idempotency_keys (expires_at)"

    # ── Oban (job queue) ─────────────────────────────────────────────────────
    execute """
    CREATE TABLE oban_jobs (
      id bigserial PRIMARY KEY,
      state oban_job_state NOT NULL DEFAULT 'available',
      queue text NOT NULL DEFAULT 'default',
      worker text NOT NULL,
      args jsonb NOT NULL DEFAULT '{}'::jsonb,
      errors jsonb[] NOT NULL DEFAULT ARRAY[]::jsonb[],
      attempt integer NOT NULL DEFAULT 0,
      max_attempts integer NOT NULL DEFAULT 20,
      inserted_at timestamp without time zone NOT NULL DEFAULT timezone('UTC'::text, now()),
      scheduled_at timestamp without time zone NOT NULL DEFAULT timezone('UTC'::text, now()),
      attempted_at timestamp without time zone,
      completed_at timestamp without time zone,
      attempted_by text[],
      discarded_at timestamp without time zone,
      priority integer NOT NULL DEFAULT 0,
      tags text[] DEFAULT ARRAY[]::text[],
      meta jsonb DEFAULT '{}'::jsonb,
      cancelled_at timestamp without time zone,
      CONSTRAINT attempt_range CHECK (attempt >= 0 AND attempt <= max_attempts),
      CONSTRAINT positive_max_attempts CHECK (max_attempts > 0),
      CONSTRAINT queue_length CHECK (char_length(queue) > 0 AND char_length(queue) < 128),
      CONSTRAINT worker_length CHECK (char_length(worker) > 0 AND char_length(worker) < 128)
    )
    """

    execute "ALTER TABLE oban_jobs ADD CONSTRAINT non_negative_priority CHECK (priority >= 0) NOT VALID"
    execute "CREATE INDEX oban_jobs_args_index ON oban_jobs USING gin (args)"
    execute "CREATE INDEX oban_jobs_meta_index ON oban_jobs USING gin (meta)"
    execute "CREATE INDEX oban_jobs_state_queue_priority_scheduled_at_id_index ON oban_jobs (state, queue, priority, scheduled_at, id)"

    execute """
    CREATE UNLOGGED TABLE oban_peers (
      name text PRIMARY KEY,
      node text NOT NULL,
      started_at timestamp without time zone NOT NULL,
      expires_at timestamp without time zone NOT NULL
    )
    """

    # ── CI log self-learning loop ────────────────────────────────────────────
    execute """
    CREATE TABLE ci_log_events (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      run_id text NOT NULL,
      workflow_name text NOT NULL,
      conclusion text NOT NULL,
      duration_ms integer NOT NULL DEFAULT 0,
      failure_summary text NOT NULL DEFAULT '',
      raw_log text NOT NULL DEFAULT '',
      analyzed_at timestamp with time zone,
      analysis jsonb,
      created_at timestamp with time zone NOT NULL DEFAULT now(),
      inserted_at timestamp(0) without time zone NOT NULL DEFAULT now(),
      updated_at timestamp(0) without time zone NOT NULL DEFAULT now()
    )
    """

    execute "CREATE UNIQUE INDEX ci_log_events_run_id_index ON ci_log_events (run_id)"
    execute "CREATE INDEX ci_log_events_analyzed_at_index ON ci_log_events (analyzed_at)"
    execute "CREATE INDEX ci_log_events_conclusion_index ON ci_log_events (conclusion)"
    execute "CREATE INDEX ci_log_events_created_at_index ON ci_log_events (created_at)"

    # ── Inbox ingestion pipeline ─────────────────────────────────────────────
    execute """
    CREATE TABLE inbox_items (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      source text NOT NULL DEFAULT 'link',
      source_id text NOT NULL,
      status text NOT NULL DEFAULT 'unread',
      title text,
      author text,
      original_text text NOT NULL DEFAULT '',
      summary text,
      extracted_urls jsonb NOT NULL DEFAULT '[]'::jsonb,
      extracted_repos jsonb NOT NULL DEFAULT '[]'::jsonb,
      eval_result jsonb,
      card_id text,
      metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      ingested_at timestamp with time zone NOT NULL DEFAULT now(),
      inserted_at timestamp(0) without time zone NOT NULL DEFAULT now(),
      updated_at timestamp(0) without time zone NOT NULL DEFAULT now()
    )
    """

    execute "CREATE UNIQUE INDEX inbox_items_source_source_id_index ON inbox_items (source, source_id)"
    execute "CREATE INDEX inbox_items_status_index ON inbox_items (status)"
    execute "CREATE INDEX inbox_items_created_at_index ON inbox_items (inserted_at DESC)"
  end

  def down do
    execute "DROP TABLE IF EXISTS inbox_items CASCADE"
    execute "DROP TABLE IF EXISTS ci_log_events CASCADE"
    execute "DROP TABLE IF EXISTS oban_peers CASCADE"
    execute "DROP TABLE IF EXISTS oban_jobs CASCADE"
    execute "DROP TABLE IF EXISTS idempotency_keys CASCADE"
    execute "DROP TABLE IF EXISTS agent_jobs CASCADE"
    execute "DROP TABLE IF EXISTS sessions CASCADE"
    execute "DROP TABLE IF EXISTS users CASCADE"
    execute "DROP TABLE IF EXISTS audit_events CASCADE"
    execute "DROP TABLE IF EXISTS conversation_history CASCADE"
    execute "DROP TABLE IF EXISTS trace_events CASCADE"
    execute "DROP TABLE IF EXISTS workflow_runs CASCADE"
    execute "DROP TABLE IF EXISTS card_events CASCADE"
    execute "DROP TABLE IF EXISTS cards CASCADE"
    execute "DROP TABLE IF EXISTS workspaces CASCADE"
    execute "DROP TYPE IF EXISTS oban_job_state"
  end
end
