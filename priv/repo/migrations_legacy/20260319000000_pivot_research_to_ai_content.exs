defmodule Crucible.Repo.Migrations.PivotResearchToAiContent do
  use Ecto.Migration

  def up do
    # --- Alter research_projects: remove crypto columns, add AI content columns ---
    execute """
    ALTER TABLE research_projects
      DROP COLUMN IF EXISTS ticker,
      DROP COLUMN IF EXISTS chain,
      DROP COLUMN IF EXISTS coingecko_id,
      DROP COLUMN IF EXISTS defillama_id,
      DROP COLUMN IF EXISTS allium_schema
    """

    execute """
    ALTER TABLE research_projects
      ADD COLUMN IF NOT EXISTS topic_area TEXT,
      ADD COLUMN IF NOT EXISTS readwise_tag TEXT,
      ADD COLUMN IF NOT EXISTS source_urls JSONB NOT NULL DEFAULT '[]',
      ADD COLUMN IF NOT EXISTS content_type TEXT NOT NULL DEFAULT 'article'
    """

    # --- Alter project_scores: remove crypto dimensions, add content dimensions ---
    execute """
    ALTER TABLE project_scores
      DROP COLUMN IF EXISTS fundamentals,
      DROP COLUMN IF EXISTS momentum,
      DROP COLUMN IF EXISTS derivatives,
      DROP COLUMN IF EXISTS social,
      DROP COLUMN IF EXISTS development,
      DROP COLUMN IF EXISTS risk
    """

    execute """
    ALTER TABLE project_scores
      ADD COLUMN IF NOT EXISTS novelty JSONB NOT NULL DEFAULT '{}',
      ADD COLUMN IF NOT EXISTS depth JSONB NOT NULL DEFAULT '{}',
      ADD COLUMN IF NOT EXISTS relevance JSONB NOT NULL DEFAULT '{}',
      ADD COLUMN IF NOT EXISTS citation_potential JSONB NOT NULL DEFAULT '{}',
      ADD COLUMN IF NOT EXISTS audience_fit JSONB NOT NULL DEFAULT '{}',
      ADD COLUMN IF NOT EXISTS completeness JSONB NOT NULL DEFAULT '{}'
    """

    # --- Drop tables no longer needed ---
    execute "DROP TABLE IF EXISTS price_data"
    execute "DROP TABLE IF EXISTS derivatives_data"

    # --- Drop readwise_highlights (Readwise integration removed) ---
    execute "DROP TABLE IF EXISTS readwise_highlights"
  end

  def down do
    # --- Recreate readwise_highlights (restore if rolling back) ---
    execute """
    CREATE TABLE IF NOT EXISTS readwise_highlights (
      id TEXT PRIMARY KEY,
      highlight_text TEXT NOT NULL,
      source_title TEXT,
      source_author TEXT,
      source_url TEXT,
      readwise_id TEXT,
      readwise_book_id TEXT,
      tags JSONB NOT NULL DEFAULT '[]',
      note TEXT,
      highlighted_at TIMESTAMPTZ,
      synced_at TIMESTAMPTZ,
      metadata JSONB NOT NULL DEFAULT '{}',
      project_id TEXT REFERENCES research_projects(id),
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """

    create_if_not_exists index(:readwise_highlights, [:project_id])
    create_if_not_exists unique_index(:readwise_highlights, [:readwise_id])
    create_if_not_exists index(:readwise_highlights, [:highlighted_at])

    # --- Restore project_scores crypto dimensions ---
    execute """
    ALTER TABLE project_scores
      DROP COLUMN IF EXISTS novelty,
      DROP COLUMN IF EXISTS depth,
      DROP COLUMN IF EXISTS relevance,
      DROP COLUMN IF EXISTS citation_potential,
      DROP COLUMN IF EXISTS audience_fit,
      DROP COLUMN IF EXISTS completeness
    """

    execute """
    ALTER TABLE project_scores
      ADD COLUMN IF NOT EXISTS fundamentals JSONB NOT NULL DEFAULT '{}',
      ADD COLUMN IF NOT EXISTS momentum JSONB NOT NULL DEFAULT '{}',
      ADD COLUMN IF NOT EXISTS derivatives JSONB NOT NULL DEFAULT '{}',
      ADD COLUMN IF NOT EXISTS social JSONB NOT NULL DEFAULT '{}',
      ADD COLUMN IF NOT EXISTS development JSONB NOT NULL DEFAULT '{}',
      ADD COLUMN IF NOT EXISTS risk JSONB NOT NULL DEFAULT '{}'
    """

    # --- Restore research_projects crypto columns ---
    execute """
    ALTER TABLE research_projects
      DROP COLUMN IF EXISTS topic_area,
      DROP COLUMN IF EXISTS readwise_tag,
      DROP COLUMN IF EXISTS source_urls,
      DROP COLUMN IF EXISTS content_type
    """

    execute """
    ALTER TABLE research_projects
      ADD COLUMN IF NOT EXISTS ticker TEXT,
      ADD COLUMN IF NOT EXISTS chain TEXT,
      ADD COLUMN IF NOT EXISTS coingecko_id TEXT,
      ADD COLUMN IF NOT EXISTS defillama_id TEXT,
      ADD COLUMN IF NOT EXISTS allium_schema TEXT
    """

    # --- Recreate price_data ---
    execute """
    CREATE TABLE IF NOT EXISTS price_data (
      id BIGSERIAL PRIMARY KEY,
      project_id TEXT NOT NULL REFERENCES research_projects(id),
      price_usd NUMERIC NOT NULL,
      volume_24h NUMERIC,
      mcap NUMERIC,
      price_change_pct_24h NUMERIC,
      source TEXT NOT NULL DEFAULT 'coingecko',
      snapshot_at TIMESTAMPTZ NOT NULL,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """

    create_if_not_exists index(:price_data, [:project_id, :snapshot_at])

    # --- Recreate derivatives_data ---
    execute """
    CREATE TABLE IF NOT EXISTS derivatives_data (
      id BIGSERIAL PRIMARY KEY,
      project_id TEXT NOT NULL REFERENCES research_projects(id),
      exchange TEXT NOT NULL,
      oi_usd NUMERIC,
      funding_rate NUMERIC,
      cvd NUMERIC,
      long_short_ratio NUMERIC,
      liquidations_24h NUMERIC,
      snapshot_at TIMESTAMPTZ NOT NULL,
      metadata JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """

    create_if_not_exists index(:derivatives_data, [:project_id, :snapshot_at])
  end
end
