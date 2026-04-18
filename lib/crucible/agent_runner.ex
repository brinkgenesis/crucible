defmodule Crucible.AgentRunner do
  @moduledoc """
  Per-run execution flow. Spawned as a supervised Task by the Orchestrator.
  Mirrors Symphony's AgentRunner: workspace setup → phase loop → PR creation.
  """

  require Logger

  alias Crucible.Types.{Run, Phase}
  alias Crucible.{Events, PhaseRunner, Workspace, BudgetTracker, ResultWriter, LoopManager}
  alias Crucible.Kanban.DbAdapter

  @doc """
  Runs a complete workflow. Called within a Task.Supervisor child.
  The orchestrator_pid receives {:agent_update, run_id, update} messages.
  """
  @spec run(Run.t(), pid(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%Run{} = run, orchestrator_pid \\ self(), opts \\ []) do
    Logger.info("AgentRunner: starting run #{run.id} (#{run.workflow_type})")
    started_at = System.monotonic_time(:millisecond)

    run =
      case Workspace.ensure_branch(run) do
        {:ok, worktree_path} -> %{run | workspace_path: worktree_path}
        :ok -> run
        {:error, reason} -> throw({:branch_error, reason})
      end

    with {:ok, results} <- execute_phases(run, orchestrator_pid, opts) do
      elapsed = System.monotonic_time(:millisecond) - started_at

      phases_map =
        results
        |> Enum.map(fn {phase_id, phase_result} ->
          phase_result
          |> sanitize_for_json()
          |> Map.put("phase_id", phase_id)
        end)

      result = %{
        run_id: run.id,
        status: "completed",
        phases: phases_map,
        elapsed_ms: elapsed
      }

      ResultWriter.write_result(run.id, result)
      cleanup_run_artifacts(run)
      maybe_create_output_card(run, result)

      Phoenix.PubSub.broadcast(
        Crucible.PubSub,
        "orchestrator:runs",
        {:run_completed, run.id}
      )

      {:ok, result}
    else
      {:error, :budget_paused} = error ->
        elapsed = System.monotonic_time(:millisecond) - started_at
        Logger.info("AgentRunner: run #{run.id} paused after #{elapsed}ms (budget exceeded)")
        error

      {:error, reason} = error ->
        elapsed = System.monotonic_time(:millisecond) - started_at

        result = %{
          run_id: run.id,
          status: "failed",
          error: inspect(reason),
          elapsed_ms: elapsed
        }

        ResultWriter.write_result(run.id, result)
        Logger.error("AgentRunner: run #{run.id} failed after #{elapsed}ms: #{inspect(reason)}")
        error
    end
  catch
    {:branch_error, reason} ->
      Logger.error("AgentRunner: branch setup failed for #{run.id}: #{inspect(reason)}")
      {:error, {:branch_error, reason}}
  after
    maybe_cleanup_worktree(run)
  end

  # --- Phase execution with dependency resolution ---

  defp execute_phases(run, orchestrator_pid, opts) do
    do_execute_phases(run, run.phases, MapSet.new(), [], orchestrator_pid, opts)
  end

  defp do_execute_phases(_run, [], _completed, results, _pid, _opts) do
    {:ok, Enum.reverse(results)}
  end

  defp do_execute_phases(run, remaining, completed, results, orchestrator_pid, opts) do
    # completed tracks both phase IDs and phase names so depends_on can reference either
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

      [phase | rest_ready] ->
        # Budget gate between phases
        if BudgetTracker.daily_status().exceeded? do
          Logger.warning("AgentRunner: budget exceeded, pausing run #{run.id}")

          ResultWriter.transition_run_status(
            run.id,
            "budget_paused",
            "budget-#{run.id}-#{System.monotonic_time(:millisecond)}"
          )

          notify(orchestrator_pid, run.id, :budget_paused, %{phase_id: phase.id})
          {:error, :budget_paused}
        else
          # Pre-phase: create branch if this phase requires it
          run = maybe_create_branch(run, phase)

          update_manifest_phase_status(run, phase, "in_progress")
          notify(orchestrator_pid, run.id, :phase_start, %{phase_id: phase.id})
          Events.broadcast_phase_event(run.id, phase.id, :started)

          # Move card to "review" when PR shepherd phase starts
          if phase.type == :pr_shepherd do
            maybe_move_card_to_review(run)
          end

          :telemetry.execute(
            [:orchestrator, :phase, :start],
            %{system_time: System.system_time(:millisecond)},
            %{run_id: run.id, phase_id: phase.id, phase_type: phase.type}
          )

          # Start reviewer watch for team phases (moves card to "review" when reviewer agent starts)
          reviewer_task = maybe_start_reviewer_watch(run, phase)

          case execute_single_phase(run, phase, opts) do
            {:ok, result} ->
              if reviewer_task, do: Task.shutdown(reviewer_task, :brutal_kill)

              update_manifest_phase_status(run, phase, "completed")
              notify(orchestrator_pid, run.id, :phase_complete, %{phase_id: phase.id})
              Events.broadcast_phase_event(run.id, phase.id, :completed)

              # Post-phase: sync phase statuses to card metadata
              sync_phase_to_card(run, phase, "completed")

              # Post-phase: flush trace events to DB for dashboard/KPI visibility
              flush_traces_to_db(run)

              # Post-phase: create PR after createBranch phase completes
              run = maybe_create_pr(run, phase)

              # Post-phase: checkout main after pr-shepherd completes
              maybe_checkout_main(run, phase)

              # Add both id and name so depends_on can reference either
              new_completed =
                completed
                |> MapSet.put(phase.id)
                |> MapSet.put(phase.name)

              do_execute_phases(
                run,
                rest_ready ++ blocked,
                new_completed,
                [{phase.id, result} | results],
                orchestrator_pid,
                opts
              )

            {:error, _} = error ->
              if reviewer_task, do: Task.shutdown(reviewer_task, :brutal_kill)

              update_manifest_phase_status(run, phase, "failed")
              sync_phase_to_card(run, phase, "failed")
              flush_traces_to_db(run)
              notify(orchestrator_pid, run.id, :phase_failed, %{phase_id: phase.id})
              Events.broadcast_phase_event(run.id, phase.id, :failed)
              error
          end
        end
    end
  end

  defp execute_single_phase(run, %Phase{} = phase, opts) do
    case PhaseRunner.execute(run, phase, opts) do
      {:ok, _} = success ->
        success

      {:error, reason} when phase.retry_count < phase.max_retries ->
        Logger.warning(
          "AgentRunner: phase #{phase.id} retry #{phase.retry_count + 1}/#{phase.max_retries}: #{inspect(reason)}"
        )

        backoff = min(5_000 * :math.pow(2, phase.retry_count), 60_000) |> round()
        Process.sleep(backoff)
        execute_single_phase(run, %{phase | retry_count: phase.retry_count + 1}, opts)

      {:error, _} = error ->
        error
    end
  end

  defp notify(pid, run_id, type, data) do
    send(pid, {:agent_update, run_id, Map.put(data, :type, type)})
  end

  # --- Output card creation (onCompleteCreateCard) ---

  # --- Branch, PR, and manifest lifecycle ---

  defp maybe_create_branch(run, phase) do
    if phase.create_branch and is_nil(run.branch) do
      case LoopManager.ensure_run_branch(run) do
        {:ok, updated_run} ->
          Logger.info("AgentRunner: created branch #{updated_run.branch} for phase #{phase.id}")
          updated_run

        {:error, reason} ->
          Logger.warning("AgentRunner: branch creation failed for #{phase.id}: #{inspect(reason)}")
          run
      end
    else
      run
    end
  end

  defp maybe_create_pr(run, phase) do
    if phase.create_branch and is_binary(run.branch) do
      # Safety net: if coder forgot to commit, auto-commit any changes
      auto_commit_uncommitted_changes(run)

      case LoopManager.create_pull_request(run) do
        {:ok, pr_info} ->
          Logger.info("AgentRunner: created PR ##{pr_info[:pr_number]} for run #{run.id}")
          existing_branch = run.pull_request && run.pull_request.branch_name
          pr = %{branch_name: existing_branch, number: pr_info[:pr_number], url: pr_info[:pr_url]}
          %{run | pull_request: pr}

        {:error, reason} ->
          Logger.warning("AgentRunner: PR creation failed for #{run.id}: #{inspect(reason)}")
          run
      end
    else
      run
    end
  end

  defp auto_commit_uncommitted_changes(run) do
    cwd = run.workspace_path || File.cwd!()

    # Check if there are uncommitted changes
    case System.cmd("git", ["status", "--porcelain"], cd: cwd, stderr_to_stdout: true) do
      {output, 0} when output != "" ->
        Logger.warning("AgentRunner: coder left uncommitted changes for #{run.id}, auto-committing")

        System.cmd("git", ["add", "-A"], cd: cwd, stderr_to_stdout: true)

        System.cmd(
          "git",
          ["commit", "-m", "feat: auto-commit changes from workflow #{run.id}"],
          cd: cwd,
          stderr_to_stdout: true
        )

      _ ->
        :ok
    end
  rescue
    e -> Logger.warning("AgentRunner: auto-commit check failed: #{Exception.message(e)}")
  end

  defp maybe_checkout_main(run, phase) do
    if phase.type == :pr_shepherd and is_binary(run.branch) do
      cwd = run.workspace_path || File.cwd!()
      LoopManager.cleanup_after_merge(cwd)
    end
  end

  defp maybe_cleanup_worktree(%Run{workspace_path: path}) when is_binary(path) do
    if String.contains?(path, ".claude-flow/worktrees/") do
      Workspace.cleanup_worktree(path)
    end
  end

  defp maybe_cleanup_worktree(_run), do: :ok

  defp update_manifest_phase_status(run, phase, status) do
    config = Application.get_env(:crucible, :orchestrator, [])
    repo_root = Keyword.get(config, :repo_root, File.cwd!())
    runs_dir = Keyword.get(config, :runs_dir, Path.join(repo_root, ".claude-flow/runs"))
    path = Path.join(runs_dir, "#{run.id}.json")

    with {:ok, content} <- File.read(path),
         {:ok, manifest} <- Jason.decode(content) do
      phases = manifest["phases"] || []

      updated_phases =
        Enum.map(phases, fn p ->
          phase_name = p["phaseName"] || p["name"] || ""

          if phase_name == phase.name or p["id"] == phase.id do
            Map.put(p, "status", status)
          else
            p
          end
        end)

      updated = Map.put(manifest, "phases", updated_phases)

      case Jason.encode(updated, pretty: true) do
        {:ok, json} -> File.write(path, json)
        _ -> :ok
      end
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  # --- Reviewer lifecycle watch ---

  defp maybe_move_card_to_review(run) do
    card_id = get_card_id_for_run(run.id)

    if card_id do
      DbAdapter.update_card(card_id, %{column: "review"})
      Logger.info("AgentRunner: PR shepherd starting for #{run.id} — card moved to review")
    end
  rescue
    e -> Logger.warning("AgentRunner: card review move failed: #{Exception.message(e)}")
  end

  defp maybe_start_reviewer_watch(run, phase) do
    if phase.type == :team and has_reviewer?(phase) do
      Task.Supervisor.async_nolink(Crucible.TaskSupervisor, fn ->
        watch_for_reviewer(run, phase)
      end)
    else
      nil
    end
  end

  defp has_reviewer?(phase) do
    agents = phase.agents || []
    Enum.any?(agents, fn
      a when is_binary(a) -> a == "reviewer"
      %{role: role} -> role == "reviewer"
      _ -> false
    end)
  end


  defp watch_for_reviewer(run, phase) do
    config = Application.get_env(:crucible, :orchestrator, [])
    repo_root = Keyword.get(config, :repo_root, File.cwd!())
    lifecycle_path = Path.join(repo_root, ".claude-flow/logs/agent-lifecycle.jsonl")
    team_name = LoopManager.team_name_for_phase(run, phase)

    # Poll lifecycle log every 5s for reviewer idle event
    poll_reviewer_lifecycle(lifecycle_path, team_name, run, 0, 120)
  end

  defp poll_reviewer_lifecycle(_path, _team, _run, attempt, max) when attempt >= max, do: :ok

  defp poll_reviewer_lifecycle(path, team_name, run, attempt, max) do
    Process.sleep(5_000)

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          # Check last 32KB for reviewer idle events
          tail = if byte_size(content) > 32_768, do: binary_part(content, byte_size(content) - 32_768, 32_768), else: content

          if String.contains?(tail, "reviewer") and String.contains?(tail, team_name) do
            # Reviewer started — move card to review
            card_id = get_card_id_for_run(run.id)

            if card_id do
              DbAdapter.update_card(card_id, %{column: "review"})
              Logger.info("AgentRunner: reviewer detected for #{run.id} — card moved to review")
            end

            :ok
          else
            poll_reviewer_lifecycle(path, team_name, run, attempt + 1, max)
          end

        _ ->
          poll_reviewer_lifecycle(path, team_name, run, attempt + 1, max)
      end
    else
      poll_reviewer_lifecycle(path, team_name, run, attempt + 1, max)
    end
  end

  defp get_card_id_for_run(run_id) do
    Crucible.WorkflowPersistence.get_card_id(run_id)
  end

  # --- Phase card sync ---

  defp sync_phase_to_card(run, phase, status) do
    card_id = get_card_id_for_run(run.id)

    if card_id do
      phase_statuses = %{phase.id => status, phase.name => status}
      ResultWriter.sync_phase_cards(card_id, phase_statuses)
    end
  rescue
    e -> Logger.warning("AgentRunner: phase card sync failed: #{Exception.message(e)}")
  end

  # --- Trace DB flush ---

  defp flush_traces_to_db(run) do
    config = Application.get_env(:crucible, :orchestrator, [])
    repo_root = Keyword.get(config, :repo_root, File.cwd!())
    trace_path = Path.join(repo_root, ".claude-flow/logs/traces/#{run.id}.jsonl")

    if File.exists?(trace_path) do
      alias Crucible.{Repo, Schema.TraceEvent}

      trace_path
      |> File.stream!()
      |> Stream.each(fn line ->
        with {:ok, event} <- Jason.decode(line) do
          attrs = %{
            trace_id: event["traceId"] || "#{event["runId"]}-#{:erlang.unique_integer([:positive])}",
            run_id: event["runId"],
            phase_id: event["phaseId"],
            session_id: event["sessionId"],
            agent_id: event["agentId"],
            event_type: event["eventType"],
            tool: event["tool"],
            detail: event["detail"],
            metadata: event["metadata"],
            client_id: event["clientId"],
            timestamp: parse_trace_timestamp(event["timestamp"])
          }

          %TraceEvent{}
          |> TraceEvent.changeset(attrs)
          |> Repo.insert(on_conflict: :nothing)
        end
      end)
      |> Stream.run()

      Logger.debug("AgentRunner: flushed traces to DB for run #{run.id}")
    end
  rescue
    e -> Logger.warning("AgentRunner: trace flush failed for #{run.id}: #{Exception.message(e)}")
  end

  defp parse_trace_timestamp(nil), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp parse_trace_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  # --- Post-run cleanup ---

  defp cleanup_run_artifacts(run) do
    # Clean residual in_progress tasks from completed team phases
    cleanup_residual_tasks(run)
    # Remove stale .wake, .task-status, and .pr-*.json signal files
    cleanup_run_signals(run)
    Crucible.PrCounter.cleanup(run.id)
  rescue
    e -> Logger.warning("AgentRunner: cleanup failed for #{run.id}: #{Exception.message(e)}")
  end

  defp cleanup_residual_tasks(run) do
    Enum.each(run.phases, fn phase ->
      if phase.type == :team do
        team_name = LoopManager.team_name_for_phase(run, phase)
        task_dir = Path.expand("~/.claude/tasks/#{team_name}")

        if File.dir?(task_dir) do
          task_dir
          |> File.ls!()
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.each(fn file ->
            path = Path.join(task_dir, file)

            with {:ok, content} <- File.read(path),
                 {:ok, %{"status" => "in_progress"} = task} <- Jason.decode(content) do
              updated =
                task
                |> Map.put("status", "completed")
                |> Map.put("forceCompleted", true)
                |> Map.put("updatedAt", DateTime.utc_now() |> DateTime.to_iso8601())

              case Jason.encode(updated, pretty: true) do
                {:ok, json} -> File.write!(path, json)
                _ -> :ok
              end

              Logger.debug("AgentRunner: force-completed residual task #{file}")
            else
              _ -> :ok
            end
          end)
        end
      end
    end)
  end

  defp cleanup_run_signals(run) do
    config = Application.get_env(:crucible, :orchestrator, [])
    repo_root = Keyword.get(config, :repo_root, File.cwd!())
    signal_dir = Path.join(repo_root, ".claude-flow/signals")

    if File.dir?(signal_dir) do
      signal_dir
      |> File.ls!()
      |> Enum.filter(fn f ->
        String.contains?(f, run.id) or
          Enum.any?(run.phases, fn phase ->
            team = LoopManager.team_name_for_phase(run, phase)
            String.starts_with?(f, team)
          end)
      end)
      |> Enum.each(fn f ->
        File.rm(Path.join(signal_dir, f))
      end)
    end
  end

  defp maybe_create_output_card(%Run{on_complete_create_card: nil}, _result), do: :ok

  defp maybe_create_output_card(%Run{on_complete_create_card: card_config} = run, result)
       when is_map(card_config) do
    card =
      Map.merge(card_config, %{
        "source_run_id" => run.id,
        "workflow_type" => run.workflow_type,
        "auto_generated" => true,
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "run_status" => to_string(result[:status] || :completed)
      })

    dir = ".claude-flow/cards"
    File.mkdir_p!(dir)
    card_id = :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
    path = Path.join(dir, "#{card_id}.json")

    case Jason.encode(card, pretty: true) do
      {:ok, json} ->
        File.write!(path, json)
        Logger.info("AgentRunner: created output card #{card_id} for run #{run.id}")

      {:error, reason} ->
        Logger.warning("AgentRunner: failed to encode output card: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("AgentRunner: output card creation failed: #{inspect(e)}")
  end

  defp maybe_create_output_card(_, _), do: :ok

  # Recursively convert a map/struct to JSON-safe types
  defp sanitize_for_json(%_{} = struct), do: struct |> Map.from_struct() |> sanitize_for_json()

  defp sanitize_for_json(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), sanitize_for_json(v)} end)
  end

  defp sanitize_for_json(list) when is_list(list), do: Enum.map(list, &sanitize_for_json/1)
  defp sanitize_for_json(atom) when is_atom(atom), do: to_string(atom)
  defp sanitize_for_json(other), do: other
end
