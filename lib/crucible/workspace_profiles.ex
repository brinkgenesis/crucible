defmodule Crucible.WorkspaceProfiles do
  @moduledoc "CRUD context for workspace profiles."

  alias Crucible.{AuditLog, Repo}
  alias Crucible.Schema.WorkspaceProfile

  import Ecto.Query

  @spec list_workspaces() :: [WorkspaceProfile.t()]
  def list_workspaces do
    WorkspaceProfile |> order_by(:name) |> Repo.all()
  end

  @spec get_workspace(String.t() | nil) :: WorkspaceProfile.t() | nil
  def get_workspace(id) when is_binary(id), do: Repo.get(WorkspaceProfile, id)
  def get_workspace(_), do: nil

  @spec get_workspace_by_slug(String.t()) :: WorkspaceProfile.t() | nil
  def get_workspace_by_slug(slug) when is_binary(slug) do
    Repo.get_by(WorkspaceProfile, slug: slug)
  end

  @spec default_workspace() :: WorkspaceProfile.t() | nil
  def default_workspace do
    Repo.get_by(WorkspaceProfile, slug: "infra")
  end

  @spec create_workspace(map()) :: {:ok, WorkspaceProfile.t()} | {:error, Ecto.Changeset.t()}
  def create_workspace(attrs) do
    result =
      %WorkspaceProfile{id: Ecto.UUID.generate()}
      |> WorkspaceProfile.changeset(attrs)
      |> Repo.insert()

    with {:ok, ws} <- result do
      AuditLog.log("workspace", ws.id, "created", %{name: ws.name, slug: ws.slug}, actor: "context:WorkspaceProfiles")
      {:ok, ws}
    end
  end

  @spec update_workspace(WorkspaceProfile.t(), map()) :: {:ok, WorkspaceProfile.t()} | {:error, Ecto.Changeset.t()}
  def update_workspace(%WorkspaceProfile{} = ws, attrs) do
    result = ws |> WorkspaceProfile.changeset(attrs) |> Repo.update()

    with {:ok, updated} <- result do
      AuditLog.log("workspace", ws.id, "updated", %{fields: Map.keys(attrs)}, actor: "context:WorkspaceProfiles")
      {:ok, updated}
    end
  end

  @spec delete_workspace(WorkspaceProfile.t()) :: {:ok, WorkspaceProfile.t()} | {:error, Ecto.Changeset.t()}
  def delete_workspace(%WorkspaceProfile{} = ws) do
    result = Repo.delete(ws)

    with {:ok, deleted} <- result do
      AuditLog.log("workspace", ws.id, "deleted", %{name: ws.name}, actor: "context:WorkspaceProfiles")
      {:ok, deleted}
    end
  end
end
