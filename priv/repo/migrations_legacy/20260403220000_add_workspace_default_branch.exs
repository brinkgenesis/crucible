defmodule Crucible.Repo.Migrations.AddWorkspaceDefaultBranch do
  use Ecto.Migration

  def change do
    alter table(:workspaces) do
      add :default_branch, :string, default: "main"
    end
  end
end
