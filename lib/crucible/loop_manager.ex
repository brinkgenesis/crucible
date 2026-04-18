defmodule Crucible.LoopManager do
  @moduledoc """
  Multi-phase dependency resolution and PR lifecycle management.
  Ports loop-manager.ts: phase ordering, branch/PR creation, stuck-task detection.
  """

  require Logger

  alias Crucible.Types.Run
  alias Crucible.{PhaseRunner, BudgetTracker, ResultWriter, Workspace, Repo}
  alias Crucible.Schema.{Card, WorkspaceProfile}
  alias Crucible.Claude.Protocol

  @stuck_threshold_ms 10 * 60_000

  @doc """
  Executes all phases in dependency order.
  Returns `{:ok, results}` when all phases complete, or `{:error, reason}` on failure.
  """
  @spec execute_phases(Run.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def execute_phases(%Run{} = run, opts \\ []) do
    orchestrator_pid = Keyword.get(opts, :orchestrator_pid, self())
    runs_dir = Keyword.get(opts, :runs_dir, ".claude-flow/runs")

    # Build initial completed set from any already-done phases (crash recovery)
    completed =
      run.phases
      |> Enum.filter(&(&1.status == :completed))
      |> Enum.map(& &1.id)
      |> MapSet.new()

    do_loop(run, run.phases, completed, [], orchestrator_pid, runs_dir)
  end

  # --- Branch & PR management ---

  @doc """
  Ensures the run branch exists and is checked out.
  Idempotent: if `run.branch` is already set, checks it out.
  """
  @spec ensure_run_branch(Run.t()) :: {:ok, Run.t()} | {:error, term()}
  def ensure_run_branch(%Run{branch: branch} = run) when is_binary(branch) do
    case Workspace.ensure_branch(run) do
      {:ok, worktree_path} -> {:ok, %{run | workspace_path: worktree_path}}
      error -> error
    end
  end

  def ensure_run_branch(%Run{} = run) do
    branch = "run/#{String.slice(run.id, 0, 12)}"
    run = %{run | branch: branch}

    case Workspace.ensure_branch(run) do
      {:ok, worktree_path} -> {:ok, %{run | workspace_path: worktree_path}}
      error -> error
    end
  end

  @doc """
  Creates a pull request for the run's branch.
  Idempotent: checks for existing PR first.
  """
  @spec create_pull_request(Run.t()) :: {:ok, map()} | {:error, term()}
  def create_pull_request(%Run{branch: nil}), do: {:error, :no_branch}

  def create_pull_request(%Run{} = run) do
    cwd = run.workspace_path || File.cwd!()
    base_branch = resolve_base_branch(run)

    with :ok <- assert_gh_auth(cwd),
         :ok <- git_push(run.branch, cwd),
         result <- gh_pr_create_or_find(run, cwd, base_branch) do
      result
    end
  end

  @doc """
  Cleans up after a PR merge by removing the run's worktree.
  Falls back to checkout main if the path is the repo root (non-worktree).
  Non-fatal: logs warnings but doesn't fail.
  """
  @spec cleanup_after_merge(String.t()) :: :ok
  def cleanup_after_merge(cwd) do
    if String.contains?(cwd, ".claude-flow/worktrees/") do
      Workspace.cleanup_worktree(cwd)
    else
      # Legacy fallback: if workspace_path is the repo root, just checkout main
      case System.cmd("git", ["checkout", "main"], cd: cwd, stderr_to_stdout: true) do
        {_, 0} ->
          System.cmd("git", ["pull", "--ff-only"], cd: cwd, stderr_to_stdout: true)
          :ok

        {out, _} ->
          Logger.warning("LoopManager: git checkout main failed: #{String.trim(out)}")
          :ok
      end
    end
  end

  @doc "Build deterministic team name for a workflow phase (matches TS buildTeamName)."
  @spec team_name_for_phase(Run.t(), any()) :: String.t()
  def team_name_for_phase(run, phase) do
    safe_name = run.workflow_type |> to_string() |> String.replace(~r/[^a-zA-Z0-9_-]/, "") |> String.slice(0, 12)
    run_prefix = run.id |> String.slice(0, 12)
    "#{safe_name}-#{run_prefix}-p#{phase.phase_index}"
  end

  # --- Stuck task detection ---

  @doc """
  Detects tasks stuck in `in_progress` longer than the threshold.
  """
  @spec detect_stuck_tasks(String.t(), pos_integer()) :: [map()]
  def detect_stuck_tasks(team_name, threshold_ms \\ @stuck_threshold_ms) do
    task_dir = Path.expand("~/.claude/tasks/#{team_name}")

    if File.dir?(task_dir) do
      now = System.system_time(:millisecond)

      task_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.reduce([], fn file, acc ->
        path = Path.join(task_dir, file)

        with {:ok, content} <- File.read(path),
             {:ok, %{"status" => "in_progress"} = task} <- Jason.decode(content) do
          updated_at = get_task_time(task, path)

          if now - updated_at > threshold_ms do
            [%{file: file, path: path, task: task, stuck_ms: now - updated_at} | acc]
          else
            acc
          end
        else
          _ -> acc
        end
      end)
    else
      []
    end
  end

  @doc """
  Force-completes a stuck task by updating its status JSON.
  """
  @spec force_complete_task(String.t()) :: :ok | {:error, term()}
  def force_complete_task(task_path) do
    with {:ok, content} <- File.read(task_path),
         {:ok, task} <- Jason.decode(content) do
      updated =
        task
        |> Map.put("status", "completed")
        |> Map.put("forceCompleted", true)
        |> Map.put("updatedAt", DateTime.utc_now() |> DateTime.to_iso8601())

      case Jason.encode(updated, pretty: true) do
        {:ok, json} ->
          File.write!(task_path, json)
          Logger.warning("LoopManager: force-completed stuck task #{task_path}")
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # --- Private: phase loop ---

  defp do_loop(_run, [], _completed, results, _pid, _runs_dir) do
    {:ok, Enum.reverse(results)}
  end

  defp do_loop(run, remaining, completed, results, orchestrator_pid, runs_dir) do
    {ready, blocked} =
      Enum.split_with(remaining, fn phase ->
        phase.status != :completed and
          Enum.all?(phase.depends_on, &MapSet.member?(completed, &1))
      end)

    case ready do
      [] when blocked == [] ->
        {:ok, Enum.reverse(results)}

      [] ->
        {:error, {:dependency_deadlock, Enum.map(blocked, & &1.id)}}

      _ ->
        execute_ready_phases(run, ready, blocked, completed, results, orchestrator_pid, runs_dir)
    end
  end

  defp execute_ready_phases(run, [phase | rest_ready], blocked, completed, results, pid, runs_dir) do
    # Budget gate
    if BudgetTracker.daily_status().exceeded? do
      Logger.warning("LoopManager: budget exceeded, pausing run #{run.id}")
      {:error, :budget_exceeded}
    else
      # Check for existing sentinel (crash recovery / skip)
      sentinel = Protocol.sentinel_path(runs_dir, run.id, phase.id)
      base_commit = run.branch && get_head_commit(run)

      case Protocol.read_sentinel(sentinel, base_commit) do
        {:ok, _sentinel_data} ->
          Logger.info("LoopManager: phase #{phase.id} already complete (sentinel exists)")

          do_loop(
            run,
            rest_ready ++ blocked,
            completed |> MapSet.put(phase.id) |> MapSet.put(phase.name),
            [%{phase_id: phase.id, status: :skipped} | results],
            pid,
            runs_dir
          )

        _ ->
          notify(pid, run.id, :phase_start, %{phase_id: phase.id})

          case PhaseRunner.execute(run, phase) do
            {:ok, result} ->
              notify(pid, run.id, :phase_complete, %{phase_id: phase.id})

              # Persist result
              ResultWriter.write_result("#{run.id}-#{phase.id}", result)

              do_loop(
                run,
                rest_ready ++ blocked,
                completed |> MapSet.put(phase.id) |> MapSet.put(phase.name),
                [Map.put(result, :phase_id, phase.id) | results],
                pid,
                runs_dir
              )

            {:error, _} = error ->
              notify(pid, run.id, :phase_failed, %{phase_id: phase.id})
              error
          end
      end
    end
  end

  # --- Private: git/gh helpers ---

  defp assert_gh_auth(cwd) do
    case System.cmd("gh", ["api", "/user", "--jq", ".login"],
           cd: cwd,
           stderr_to_stdout: true,
           env: gh_env()
         ) do
      {_login, 0} -> :ok
      {out, _} -> {:error, {:gh_auth_failed, String.trim(out)}}
    end
  end

  defp git_push(branch, cwd) do
    case System.cmd("git", ["push", "-u", "origin", branch],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:git_push_failed, code, String.trim(out)}}
    end
  end

  defp resolve_base_branch(%Run{card_id: card_id}) when is_binary(card_id) do
    case Repo.get(Card, card_id) do
      %Card{workspace_id: ws_id} when is_binary(ws_id) ->
        case Repo.get(WorkspaceProfile, ws_id) do
          %WorkspaceProfile{default_branch: branch} when is_binary(branch) and branch != "" ->
            branch

          _ ->
            "main"
        end

      _ ->
        "main"
    end
  rescue
    _ -> "main"
  end

  defp resolve_base_branch(_), do: "main"

  defp gh_pr_create_or_find(%Run{} = run, cwd, base_branch) do
    # Check for existing PR
    case System.cmd("gh", ["pr", "view", "--head", run.branch, "--json", "number,url"],
           cd: cwd,
           stderr_to_stdout: true,
           env: gh_env()
         ) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"number" => number, "url" => url}} ->
            {:ok, %{pr_number: number, pr_url: url, existing: true}}

          _ ->
            do_create_pr(run, cwd, base_branch, 0)
        end

      _ ->
        do_create_pr(run, cwd, base_branch, 0)
    end
  end

  defp do_create_pr(_run, _cwd, _base_branch, attempt) when attempt >= 3 do
    {:error, :pr_creation_failed}
  end

  defp do_create_pr(%Run{} = run, cwd, base_branch, attempt) do
    title = "[auto] #{run.workflow_type}: #{String.slice(run.id, 0, 8)}"
    body = build_pr_body(run)

    case System.cmd(
           "gh",
           ["pr", "create", "--title", title, "--body", body, "--head", run.branch, "--base", base_branch],
           cd: cwd,
           stderr_to_stdout: true,
           env: gh_env()
         ) do
      {output, 0} ->
        case extract_pr_number(output) do
          {:ok, number} ->
            url = String.trim(output)
            {:ok, %{pr_number: number, pr_url: url, existing: false}}

          :error ->
            Logger.warning("LoopManager: PR created but couldn't extract number, retrying")
            Process.sleep(3_000)
            do_create_pr(run, cwd, base_branch, attempt + 1)
        end

      {out, _} ->
        trimmed = String.trim(out)

        # Handle "already exists" — extract URL from stderr and reuse
        case Regex.run(~r/already exists:\s*(https:\/\/\S+)/, trimmed) do
          [_, existing_url] ->
            case extract_pr_number(existing_url) do
              {:ok, number} ->
                Logger.info("LoopManager: reusing existing PR ##{number} (created by sprint agent)")
                {:ok, %{pr_number: number, pr_url: existing_url, existing: true}}

              :error ->
                {:ok, %{pr_number: 0, pr_url: existing_url, existing: true}}
            end

          _ ->
            Logger.warning(
              "LoopManager: PR creation attempt #{attempt + 1}/3 failed: #{trimmed}"
            )

            Process.sleep(3_000)
            do_create_pr(run, cwd, base_branch, attempt + 1)
        end
    end
  end

  defp build_pr_body(%Run{} = run) do
    summary = run.plan_summary || "Automated workflow run"

    """
    ## Summary
    #{summary}

    ## Details
    - **Run ID**: `#{run.id}`
    - **Workflow**: #{run.workflow_type}
    - **Phases**: #{length(run.phases)}

    ---
    _Generated by Crucible_
    """
  end

  defp extract_pr_number(output) do
    case Regex.run(~r|/pull/(\d+)|, output) do
      [_, num_str] ->
        case Integer.parse(num_str) do
          {n, _} when n > 0 -> {:ok, n}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp gh_env do
    System.get_env()
    |> Map.delete("GITHUB_TOKEN")
    |> Map.delete("GH_TOKEN")
    |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp get_head_commit(%Run{workspace_path: path}) do
    cwd = path || File.cwd!()

    case System.cmd("git", ["rev-parse", "HEAD"], cd: cwd, stderr_to_stdout: true) do
      {hash, 0} -> String.trim(hash)
      _ -> nil
    end
  end

  defp get_task_time(task, path) do
    case Map.get(task, "updatedAt") do
      ts when is_binary(ts) ->
        case DateTime.from_iso8601(ts) do
          {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
          _ -> file_mtime_ms(path)
        end

      _ ->
        file_mtime_ms(path)
    end
  end

  defp file_mtime_ms(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime * 1000
      _ -> System.system_time(:millisecond)
    end
  end

  defp notify(pid, run_id, type, data) do
    send(pid, {:agent_update, run_id, Map.put(data, :type, type)})
  end
end
