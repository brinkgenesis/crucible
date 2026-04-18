defmodule Crucible.ControlSession.CodebaseDiscovery do
  @moduledoc """
  Discovers available codebases for the Control panel's directory picker.

  Starts with the user's configured workspaces (from the DB), adds the
  current working directory, and optionally scans common project parent
  folders under `$HOME` if `CRUCIBLE_SCAN_HOME_DIRS=1` is set.
  """

  alias Crucible.Repo
  alias Crucible.Schema.WorkspaceProfile

  @doc "Returns a list of available codebases as maps with :path, :name, :description."
  @spec discover() :: [map()]
  def discover do
    workspaces = load_configured_workspaces()

    cwd = %{
      path: File.cwd!(),
      name: "crucible",
      description: "Current working directory"
    }

    scanned = if scan_home?(), do: scan_project_dirs(home()), else: []

    ([cwd] ++ workspaces ++ scanned)
    |> Enum.uniq_by(& &1.path)
    |> Enum.sort_by(& &1.name)
  end

  # --- Private ---

  defp home, do: System.get_env("HOME") || System.user_home!() || "."

  defp scan_home?, do: System.get_env("CRUCIBLE_SCAN_HOME_DIRS") == "1"

  defp load_configured_workspaces do
    Repo.all(WorkspaceProfile)
    |> Enum.map(fn ws ->
      %{
        path: Map.get(ws, :repo_path) || "",
        name: Map.get(ws, :name) || Map.get(ws, :slug) || "workspace",
        description: Map.get(ws, :tech_context) || "Configured workspace"
      }
    end)
    |> Enum.filter(&(&1.path != ""))
  rescue
    _ -> []
  end

  defp scan_project_dirs(home) do
    ["#{home}/projects", "#{home}/code", "#{home}/dev", "#{home}/repos", "#{home}/src"]
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(&list_git_repos/1)
    |> Enum.take(20)
  end

  defp list_git_repos(parent) do
    case File.ls(parent) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(parent, &1))
        |> Enum.filter(fn path ->
          File.dir?(path) and File.exists?(Path.join(path, ".git"))
        end)
        |> Enum.map(fn path ->
          %{path: path, name: Path.basename(path), description: "Git repo"}
        end)

      _ ->
        []
    end
  end
end
