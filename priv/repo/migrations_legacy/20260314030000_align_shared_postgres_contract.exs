defmodule Crucible.Repo.Migrations.AlignSharedPostgresContract do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'price_data'
          AND column_name = 'volume_24h'
      ) THEN
        ALTER TABLE price_data RENAME COLUMN volume_24h TO volume24h;
      END IF;

      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'price_data'
          AND column_name = 'price_change_pct_24h'
      ) THEN
        ALTER TABLE price_data RENAME COLUMN price_change_pct_24h TO price_change_pct24h;
      END IF;

      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'derivatives_data'
          AND column_name = 'liquidations_24h'
      ) THEN
        ALTER TABLE derivatives_data RENAME COLUMN liquidations_24h TO liquidations24h;
      END IF;
    END $$;
    """)

    execute("ALTER TABLE social_signals ADD COLUMN IF NOT EXISTS author_score NUMERIC")

    execute("ALTER TABLE social_signals ADD COLUMN IF NOT EXISTS author_tier_evidence JSONB")

    execute("ALTER TABLE social_signals ADD COLUMN IF NOT EXISTS author_tier_override TEXT")
  end

  def down do
    execute("ALTER TABLE social_signals DROP COLUMN IF EXISTS author_tier_override")
    execute("ALTER TABLE social_signals DROP COLUMN IF EXISTS author_tier_evidence")
    execute("ALTER TABLE social_signals DROP COLUMN IF EXISTS author_score")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'price_data'
          AND column_name = 'volume24h'
      ) THEN
        ALTER TABLE price_data RENAME COLUMN volume24h TO volume_24h;
      END IF;

      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'price_data'
          AND column_name = 'price_change_pct24h'
      ) THEN
        ALTER TABLE price_data RENAME COLUMN price_change_pct24h TO price_change_pct_24h;
      END IF;

      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'derivatives_data'
          AND column_name = 'liquidations24h'
      ) THEN
        ALTER TABLE derivatives_data RENAME COLUMN liquidations24h TO liquidations_24h;
      END IF;
    END $$;
    """)
  end
end
