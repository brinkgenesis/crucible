defmodule Crucible.Repo.Migrations.AddSandboxPolicyToClientConfig do
  use Ecto.Migration

  def change do
    alter table(:client_config) do
      add :sandbox_policy, :string, default: nil
    end
  end
end
