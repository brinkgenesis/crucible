defmodule Crucible.Repo.Migrations.CreateWorkspaces do
  use Ecto.Migration

  def change do
    create table(:workspaces, primary_key: false) do
      add :id, :text, primary_key: true
      add :name, :text, null: false
      add :slug, :text, null: false
      add :repo_path, :text, null: false
      add :tech_context, :text, null: false, default: ""
      add :default_workflow, :text, null: false, default: "coding-sprint"

      timestamps(type: :utc_datetime, inserted_at: :created_at)
    end

    create unique_index(:workspaces, [:slug])

    alter table(:cards) do
      add :workspace_id, references(:workspaces, type: :text, on_delete: :nilify_all)
    end

    create index(:cards, [:workspace_id])

    execute(
      """
      INSERT INTO workspaces (id, name, slug, repo_path, tech_context, default_workflow, created_at, updated_at)
      VALUES (
        '#{Ecto.UUID.generate()}',
        'Infra',
        'infra',
        '/workspace/example',
        'Dual-language monorepo: Elixir/Phoenix (primary UI + orchestrator) and TypeScript (API backend + agent runtime).

Elixir side (orchestrator/):
- Phoenix LiveView frontend at orchestrator/lib/crucible_web/live/ — all user-facing pages (kanban, budget, router, settings, etc.)
- Ecto schemas at orchestrator/lib/crucible/schema/
- Business logic at orchestrator/lib/crucible/ (kanban adapters, vault plan store, inbox, actionability)
- This is the PRIMARY UI — most feature work should target LiveView pages here

TypeScript side:
- Hono API backend at dashboard/api/ (port 4800) — serves data to LiveView via HTTP
- Agent runtime: model router (lib/router/), memory vault (lib/memory/), workflow executor (lib/cli/workflow/)
- Inbox pipeline (lib/inbox/), MCP servers (lib/mcp-servers/)',
        'coding-sprint',
        NOW(),
        NOW()
      )
      ON CONFLICT (slug) DO NOTHING
      """,
      "DELETE FROM workspaces WHERE slug = 'infra'"
    )
  end
end
