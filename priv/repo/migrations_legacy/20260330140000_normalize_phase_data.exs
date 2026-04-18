defmodule Crucible.Repo.Migrations.NormalizePhaseData do
  use Ecto.Migration

  def up do
    # Normalize camelCase phase keys to snake_case for embedded schema compatibility
    execute """
    UPDATE workflow_runs SET phases = (
      SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
          'id', p->>'id',
          'name', COALESCE(p->>'name', p->>'phaseName'),
          'type', COALESCE(p->>'type', 'session'),
          'status', COALESCE(p->>'status', 'pending'),
          'phase_index', COALESCE((p->>'phaseIndex')::int, (p->>'phase_index')::int, 0),
          'session_id', COALESCE(p->>'sessionId', p->>'session_id'),
          'retry_count', COALESCE((p->>'retryCount')::int, (p->>'retry_count')::int, 0),
          'timeout_ms', COALESCE((p->>'timeoutMs')::int, (p->>'timeout_ms')::int, 600000),
          'depends_on', COALESCE(p->'dependsOn', p->'depends_on', '[]'::jsonb),
          'agents', COALESCE(p->'agents', '{}'::jsonb),
          'create_branch', COALESCE((p->>'createBranch')::boolean, (p->>'create_branch')::boolean, false)
        )
      ), '[]'::jsonb) FROM jsonb_array_elements(phases) AS p
    ) WHERE phases IS NOT NULL AND phases != '[]'::jsonb;
    """

    # Normalize session_resume_chain: unwrap {"chain": [...]} to just [...]
    execute """
    UPDATE workflow_runs
    SET session_resume_chain = session_resume_chain->'chain'
    WHERE session_resume_chain IS NOT NULL
      AND session_resume_chain ? 'chain';
    """
  end

  def down do
    # No-op: the snake_case data works fine with old code too
    :ok
  end
end
