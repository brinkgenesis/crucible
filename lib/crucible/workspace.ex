defmodule Crucible.Workspace do
  @moduledoc """
  Git worktree management for workflow runs.
  Each run gets an isolated worktree so branch checkouts never affect the
  orchestrator's main working tree or other concurrent runs.
  """

  require Logger

  alias Crucible.Types.Run

  @branch_name_regex ~r/^[a-zA-Z0-9._\/-]+$/

  @doc """
  Creates an isolated git worktree for the run's branch.
  Returns `{:ok, worktree_path}` on success.
  If the run has no branch, returns `:ok` (no-op).
  """
  @spec ensure_branch(Run.t()) :: :ok | {:ok, String.t()} | {:error, term()}
  def ensure_branch(%Run{branch: nil}), do: :ok

  def ensure_branch(%Run{branch: branch, workspace_path: existing_path, id: id}) do
    unless Regex.match?(@branch_name_regex, branch) do
      {:error, {:invalid_branch_name, branch}}
    else
      repo_root = repo_root()
      worktree_dir = Path.join([repo_root, ".claude-flow", "worktrees"])
      worktree_path = existing_path || Path.join(worktree_dir, "run-#{String.slice(id, 0, 12)}")

      cond do
        # Worktree exists and is valid — reuse it
        File.dir?(worktree_path) and worktree_valid?(worktree_path) ->
          Logger.info("Workspace: reusing valid worktree at #{worktree_path}")
          {:ok, worktree_path}

        # Directory exists but is stale/corrupt — remove and recreate
        File.dir?(worktree_path) ->
          Logger.warning("Workspace: stale worktree at #{worktree_path}, recreating")
          cleanup_worktree(worktree_path)
          File.mkdir_p!(worktree_dir)
          create_worktree(repo_root, branch, worktree_path)

        # Fresh creation
        true ->
          File.mkdir_p!(worktree_dir)
          create_worktree(repo_root, branch, worktree_path)
      end
    end
  end

  @doc """
  Removes a git worktree and prunes stale entries.
  Non-fatal: logs warnings but always returns :ok.
  """
  @spec cleanup_worktree(String.t()) :: :ok
  def cleanup_worktree(worktree_path) do
    repo_root = repo_root()

    case System.cmd("git", ["worktree", "remove", "--force", worktree_path],
           cd: repo_root,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        Logger.info("Workspace: removed worktree at #{worktree_path}")

      {output, _} ->
        Logger.warning("Workspace: worktree remove failed: #{String.trim(output)}")
        # Force-remove the directory if git worktree remove didn't work
        case File.rm_rf(worktree_path) do
          {:ok, _} ->
            :ok

          {:error, reason, _} ->
            Logger.error("Workspace: rm_rf also failed for #{worktree_path}: #{inspect(reason)}")
        end
    end

    # Prune stale worktree entries from git's internal tracking
    System.cmd("git", ["worktree", "prune"], cd: repo_root, stderr_to_stdout: true)
    :ok
  end

  @doc """
  Prune all stale worktree entries. Call on orchestrator startup to
  clean up after crashes that skipped the after block.
  """
  @spec prune_stale_worktrees() :: :ok
  def prune_stale_worktrees do
    repo_root = repo_root()
    System.cmd("git", ["worktree", "prune"], cd: repo_root, stderr_to_stdout: true)

    worktree_dir = Path.join([repo_root, ".claude-flow", "worktrees"])

    if File.dir?(worktree_dir) do
      case File.ls(worktree_dir) do
        {:ok, entries} ->
          for entry <- entries do
            path = Path.join(worktree_dir, entry)

            if File.dir?(path) and not worktree_valid?(path) do
              Logger.info("Workspace: pruning stale worktree directory #{path}")
              cleanup_worktree(path)
            end
          end

        _ ->
          :ok
      end
    end

    :ok
  end

  # --- Private ---

  defp create_worktree(repo_root, branch, worktree_path) do
    # Branch from main explicitly — prevents inheriting wrong HEAD if
    # orchestrator's working tree is on a detached state or feature branch
    case System.cmd("git", ["worktree", "add", "-B", branch, worktree_path, "main"],
           cd: repo_root,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        Logger.info("Workspace: created worktree at #{worktree_path} on branch #{branch}")
        {:ok, worktree_path}

      {output, code} ->
        Logger.error("Workspace: git worktree add failed (#{code}): #{String.trim(output)}")

        {:error, {:git_error, code, output}}
    end
  end

  defp worktree_valid?(worktree_path) do
    # A valid worktree has a .git file (not directory) pointing to the main repo's
    # worktree tracking directory. We verify this by checking that git rev-parse
    # returns a path containing /worktrees/ — a plain subdirectory of the repo
    # would return the parent's .git instead.
    git_path = Path.join(worktree_path, ".git")

    if File.exists?(git_path) and not File.dir?(git_path) do
      case System.cmd("git", ["rev-parse", "--git-dir"],
             cd: worktree_path,
             stderr_to_stdout: true
           ) do
        {output, 0} -> String.contains?(String.trim(output), "/worktrees/")
        _ -> false
      end
    else
      false
    end
  end

  defp repo_root do
    config = Application.get_env(:crucible, :orchestrator, [])
    Keyword.get(config, :repo_root, File.cwd!())
  end
end
