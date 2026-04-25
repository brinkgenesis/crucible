defmodule Crucible.Repo.Migrations.AddLastRunStartedAtToWorkspaces do
  use Ecto.Migration

  def change do
    alter table(:workspaces) do
      add :last_run_started_at, :utc_datetime, null: true
    end
  end
end
