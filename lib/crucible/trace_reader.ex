defmodule Crucible.TraceReader do
  @moduledoc """
  Reads workflow traces and manifests.

  Prefers the shared Postgres tables populated by the TypeScript side
  (`workflow_runs`, `trace_events`) and falls back to filesystem artifacts
  while in-flight runs are still flushing or when DB state is unavailable.
  """

  import Ecto.Query

  alias Crucible.{LLMUsageReader, RollupCache}
  alias Crucible.Repo
  alias Crucible.Schema.{TraceEvent, WorkflowRun}
  alias Crucible.Telemetry.Spans

  # Pure extraction functions (phases, tools, costs, agents) also available
  # as public API via Crucible.TraceExtractors for direct use.

  @traces_rel ".claude-flow/logs/traces"
  @sessions_rel ".claude-flow/logs/sessions"
  @runs_rel ".claude-flow/runs"
  @lifecycle_rel ".claude-flow/logs/agent-lifecycle.jsonl"
  @cost_events_rel ".claude-flow/logs/cost-events.jsonl"
  @claude_projects_base Path.expand("~/.claude/projects")
  @supplemental_file_max_age_ms 30 * 60 * 1000
  @stale_running_ms 10 * 60 * 1000
  @pathological_event_count 20_000
  @cache_enabled_default Mix.env() != :test
  @list_runs_cache_ttl_ms 5_000
  @list_runs_source_cache_ttl_ms 5_000

  @doc "Reads trace events for a specific run_id, preferring Postgres."
  @spec events_for_run(String.t(), keyword()) :: [map()]
  def events_for_run(run_id, opts \\ []) do
    Spans.with_span("trace_reader.events_for_run", %{"run.id" => run_id}, fn ->
      limit = Keyword.get(opts, :limit, 500)

      case Repo.safe_query([], fn -> db_events_for_run(run_id, limit) end) do
        [] -> file_events_for_run(run_id, opts)
        events -> events
      end
    end)
  end

  @doc "Reads trace events across all runs, filtered optionally by run_id."
  @spec all_events(keyword()) :: [map()]
  def all_events(opts \\ []) do
    Spans.with_span("trace_reader.all_events", fn ->
      limit = Keyword.get(opts, :limit, 50)
      run_id = Keyword.get(opts, :run_id)

      case Repo.safe_query([], fn -> db_all_events(limit, run_id) end) do
        [] -> file_all_events(opts)
        events -> events
      end
    end)
  end

  @doc "Reads session log for a run_id/phase_id."
  @spec session_log(String.t(), String.t(), keyword()) :: String.t() | nil
  def session_log(run_id, phase_id, opts \\ []) do
    sessions_dir = Keyword.get(opts, :sessions_dir, resolve_path(@sessions_rel))
    path = Path.join(sessions_dir, "#{run_id}-#{phase_id}.log")

    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end

  @doc "Reads agent lifecycle events filtered by run_id prefix (first 8 chars)."
  @spec lifecycle_agents(String.t(), keyword()) :: [map()]
  def lifecycle_agents(run_id, opts \\ []) do
    path = Keyword.get(opts, :lifecycle_path, resolve_path(@lifecycle_rel))

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&parse_line/1)
      |> Stream.reject(&is_nil/1)
      |> Stream.filter(fn e ->
        # Match on full run_id to avoid cross-run contamination.
        # Fall back to run_id substring in team_name/session_id only when
        # the event has no run_id field (legacy Agent Teams events).
        cond do
          is_binary(e["run_id"]) and e["run_id"] != "" ->
            e["run_id"] == run_id

          true ->
            # Legacy fallback: 8-char prefix in team_name/session_id
            prefix = String.slice(run_id, 0, 8)

            Enum.any?(
              [e["team_name"], e["session_id"]],
              fn v -> is_binary(v) and String.contains?(v, prefix) end
            )
        end
      end)
      |> Enum.reduce(%{}, fn e, acc ->
        # Agent Teams: teammate_name ("coder-backend")
        # Subagents: agent_type ("coder-backend")
        name = e["teammate_name"] || e["agent_type"]

        if name do
          existing = Map.get(acc, name, %{name: name, events: []})

          updated = %{
            existing
            | events:
                existing.events ++
                  [%{event: e["event"], timestamp: e["timestamp"], session_id: e["session_id"]}]
          }

          Map.put(acc, name, updated)
        else
          acc
        end
      end)
      |> Map.values()
    else
      []
    end
  rescue
    e in [File.Error, Jason.DecodeError] ->
      require Logger
      Logger.warning("TraceReader.lifecycle_agents file error: #{Exception.message(e)}")
      []
  end

  @doc "Lists all session log files for a run, keyed by phase_id."
  @spec session_logs_for_run(String.t(), keyword()) :: %{String.t() => String.t()}
  def session_logs_for_run(run_id, opts \\ []) do
    sessions_dir = Keyword.get(opts, :sessions_dir, resolve_path(@sessions_rel))

    log_files =
      if File.dir?(sessions_dir) do
        sessions_dir
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "#{run_id}-"))
        |> Enum.filter(&String.ends_with?(&1, ".log"))
        |> Enum.map(fn filename ->
          phase_id =
            filename
            |> String.trim_leading("#{run_id}-")
            |> String.trim_trailing(".log")

          content = session_log(run_id, phase_id, opts)
          {phase_id, content}
        end)
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()
      else
        %{}
      end

    # Fallback chain for SDK runs that don't produce .log files:
    # 1. Try subagent transcripts (worktree-based runs)
    # 2. Try reading main session transcript via session_id from cost events
    cond do
      log_files != %{} ->
        log_files

      (subagent_logs = sdk_subagent_logs(run_id, opts)) != %{} ->
        subagent_logs

      true ->
        sdk_session_transcript(run_id, opts)
    end
  rescue
    e in [File.Error] ->
      require Logger
      Logger.warning("TraceReader.session_logs_for_run file error: #{Exception.message(e)}")
      %{}
  end

  # Read subagent JSONL transcripts for SDK runs that don't produce .log files.
  # Discovers transcripts by scanning Claude projects dirs for worktree-based sessions.
  @spec sdk_subagent_logs(String.t(), keyword()) :: %{String.t() => String.t()}
  defp sdk_subagent_logs(run_id, opts) do
    projects_base = Keyword.get(opts, :projects_base, @claude_projects_base)

    # Find the worktree project dir: slug contains the run_id prefix.
    # Worktree dirs truncate the run_id, so match on first 10 chars.
    run_prefix = String.slice(run_id, 0, 10)

    project_dirs =
      if File.dir?(projects_base) do
        projects_base
        |> File.ls!()
        |> Enum.filter(&String.contains?(&1, run_prefix))
        |> Enum.map(&Path.join(projects_base, &1))
      else
        []
      end

    Enum.flat_map(project_dirs, fn project_dir ->
      # Find all session dirs that have subagents/
      project_dir
      |> File.ls!()
      |> Enum.filter(fn entry ->
        subagents_dir = Path.join([project_dir, entry, "subagents"])
        File.dir?(subagents_dir)
      end)
      |> Enum.flat_map(fn session_dir ->
        subagents_path = Path.join([project_dir, session_dir, "subagents"])

        subagents_path
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(fn jsonl_file ->
          agent_id = String.trim_trailing(jsonl_file, ".jsonl")
          meta_path = Path.join(subagents_path, "#{agent_id}.meta.json")
          jsonl_path = Path.join(subagents_path, jsonl_file)

          label =
            case File.read(meta_path) do
              {:ok, raw} ->
                case Jason.decode(raw) do
                  {:ok, meta} -> meta["agentType"] || agent_id
                  _ -> agent_id
                end

              _ ->
                agent_id
            end

          content = summarize_subagent_transcript(jsonl_path)
          {label, content}
        end)
      end)
    end)
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  rescue
    _ -> %{}
  end

  # Read session transcript directly using session_id from cost events.
  # SDK runs write transcripts to ~/.claude/projects/{slug}/{sessionId}.jsonl
  # but the existing discovery only finds worktree-based sessions.
  @spec sdk_session_transcript(String.t(), keyword()) :: %{String.t() => String.t()}
  defp sdk_session_transcript(run_id, opts) do
    projects_base = Keyword.get(opts, :projects_base, @claude_projects_base)
    cost_log = Keyword.get(opts, :cost_log, resolve_path(@cost_events_rel))

    # Extract session IDs from cost events for this run
    session_ids =
      if File.exists?(cost_log) do
        cost_log
        |> File.stream!()
        |> Stream.filter(&String.contains?(&1, run_id))
        |> Stream.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, %{"session" => sid}} when is_binary(sid) and sid != "" -> [sid]
            _ -> []
          end
        end)
        |> Enum.uniq()
        |> Enum.take(10)
      else
        []
      end

    # Try direct path construction first (O(1)), fall back to scan (O(n))
    infra_home = resolve_path("")
    primary_slug = cwd_to_project_slug(infra_home)
    primary_dir = Path.join(projects_base, primary_slug)

    session_ids
    |> Enum.flat_map(fn sid ->
      # Fast path: check the primary project dir directly
      primary_path = Path.join(primary_dir, "#{sid}.jsonl")

      if File.exists?(primary_path) do
        [{sid, primary_path}]
      else
        # Slow path: scan all project dirs (handles worktrees, alternate cwds)
        project_dirs =
          if File.dir?(projects_base) do
            projects_base |> File.ls!() |> Enum.map(&Path.join(projects_base, &1))
          else
            []
          end

        Enum.find_value(project_dirs, fn dir ->
          path = Path.join(dir, "#{sid}.jsonl")
          if File.exists?(path), do: [{sid, path}]
        end) || []
      end
    end)
    |> Enum.map(fn {sid, path} ->
      label = "session-#{String.slice(sid, 0, 8)}"
      content = summarize_subagent_transcript(path)
      {label, content}
    end)
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  rescue
    _ -> %{}
  end

  defp summarize_subagent_transcript(path) do
    case File.read(path) do
      {:ok, raw} ->
        raw
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, %{"type" => "assistant", "message" => %{"content" => content}}}
            when is_list(content) ->
              Enum.flat_map(content, fn
                %{"type" => "tool_use", "name" => name, "input" => input} ->
                  detail =
                    case name do
                      n when n in ["Bash", "run_command"] ->
                        cmd = input["command"] || ""
                        "$ #{String.slice(cmd, 0, 120)}"

                      n when n in ["Read", "read_file"] ->
                        "#{input["file_path"] || ""}"

                      n when n in ["Edit", "edit_file"] ->
                        "#{input["file_path"] || ""}"

                      n when n in ["Write", "write_file"] ->
                        "#{input["file_path"] || ""}"

                      n when n in ["Grep", "search_files"] ->
                        "#{input["pattern"] || ""}"

                      _ ->
                        ""
                    end

                  ["[#{name}] #{detail}"]

                %{"type" => "text", "text" => text} when byte_size(text) > 10 ->
                  # Only include substantive text blocks (planning, explanations)
                  trimmed = String.slice(text, 0, 200)
                  if String.length(text) > 200, do: ["#{trimmed}..."], else: [trimmed]

                _ ->
                  []
              end)

            _ ->
              []
          end
        end)
        |> Enum.join("\n")

      _ ->
        nil
    end
  end

  @doc """
  Reads Claude Code session transcripts for agents in a run.
  Extracts tool_use blocks, token usage, and file changes from each agent's session JSONL.
  """
  @spec agent_transcripts(String.t(), keyword()) :: [map()]
  def agent_transcripts(run_id, opts \\ []) do
    projects_base = Keyword.get(opts, :projects_base, @claude_projects_base)
    project_slug = Keyword.get(opts, :project_slug, claude_project_slug())
    projects_dir = Path.join(projects_base, project_slug)

    lifecycle = lifecycle_agents(run_id, opts)

    lifecycle
    |> Enum.map(fn agent ->
      session_ids =
        agent.events
        |> Enum.map(& &1.session_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      parsed =
        session_ids
        |> Enum.map(fn sid ->
          path = Path.join(projects_dir, "#{sid}.jsonl")
          parse_transcript(path)
        end)

      tool_calls = Enum.flat_map(parsed, & &1.tool_calls)

      tokens =
        Enum.reduce(parsed, %{input: 0, output: 0}, fn p, acc ->
          %{input: acc.input + p.tokens.input, output: acc.output + p.tokens.output}
        end)

      files_created =
        tool_calls
        |> Enum.filter(&(&1.tool == "Write" and &1[:file_path] != nil))
        |> Enum.map(& &1.file_path)
        |> Enum.uniq()

      files_modified =
        tool_calls
        |> Enum.filter(&(&1.tool == "Edit" and &1[:file_path] != nil))
        |> Enum.map(& &1.file_path)
        |> Enum.uniq()

      %{
        agent_name: agent.name,
        session_id: List.first(session_ids),
        tool_calls: tool_calls,
        tokens: tokens,
        files_created: files_created,
        files_modified: files_modified
      }
    end)
    |> Enum.reject(fn t -> t.tool_calls == [] end)
  rescue
    e in [File.Error, Jason.DecodeError] ->
      require Logger
      Logger.warning("TraceReader.agent_transcripts error: #{Exception.message(e)}")
      []
  end

  @doc "Reads a run manifest, preferring Postgres and falling back to the JSON file."
  @spec run_manifest(String.t(), keyword()) :: map() | nil
  def run_manifest(run_id, opts \\ []) do
    case db_run_manifest(run_id) do
      nil -> file_run_manifest(run_id, opts)
      manifest -> manifest
    end
  rescue
    e in [DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] ->
      require Logger
      Logger.warning("TraceReader.run_manifest DB error: #{Exception.message(e)}")
      file_run_manifest(run_id, opts)
  end

  @doc "Reads the result JSON for a run."
  @spec result_for_run(String.t(), keyword()) :: map() | nil
  def result_for_run(run_id, opts \\ []) do
    runs_dir = Keyword.get(opts, :runs_dir, resolve_path(@runs_rel))
    path = Path.join(runs_dir, "#{run_id}.result.json")

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> data
          _ -> nil
        end

      {:error, _} ->
        nil
    end
  end

  @doc """
  Deletes all filesystem artifacts for a run: trace JSONL, session logs,
  run manifest, and result file.
  """
  @spec delete_run_files(String.t(), Path.t()) :: :ok
  def delete_run_files(run_id, base_dir) do
    traces_dir = Path.join(base_dir, ".claude-flow/logs/traces")
    sessions_dir = Path.join(base_dir, ".claude-flow/logs/sessions")
    runs_dir = Path.join(base_dir, ".claude-flow/runs")

    # Trace JSONL
    File.rm(Path.join(traces_dir, "#{run_id}.jsonl"))

    # Session logs (may have phase suffix: {run_id}-{phase_id}.log)
    if File.dir?(sessions_dir) do
      sessions_dir
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, run_id))
      |> Enum.each(&File.rm(Path.join(sessions_dir, &1)))
    end

    # Run manifest + result
    File.rm(Path.join(runs_dir, "#{run_id}.json"))
    File.rm(Path.join(runs_dir, "#{run_id}.result.json"))

    :ok
  end

  @doc "Lists trace runs, preferring Postgres and falling back to JSONL scan."
  @spec list_runs(keyword()) :: [map()]
  def list_runs(opts \\ []) do
    Spans.with_span("trace_reader.list_runs", fn ->
      since = Keyword.get(opts, :since)
      client_id = Keyword.get(opts, :client_id)
      workspace = Keyword.get(opts, :workspace)

      with_rollup_cache(
        opts,
        {
          :trace_reader,
          :list_runs,
          normalize_cache_since(since),
          normalize_cache_scope(client_id),
          normalize_cache_scope(workspace),
          Keyword.get(opts, :traces_dir),
          Keyword.get(opts, :runs_dir)
        },
        @list_runs_cache_ttl_ms,
        fn -> do_list_runs(opts, since, client_id, workspace) end
      )
    end)
  rescue
    e in [
      DBConnection.ConnectionError,
      DBConnection.OwnershipError,
      Postgrex.Error,
      File.Error,
      ArgumentError
    ] ->
      require Logger
      Logger.warning("TraceReader.list_runs error: #{Exception.message(e)}")

      file_list_runs(opts, Keyword.get(opts, :since))
      |> maybe_filter_runs_workspace(Keyword.get(opts, :workspace))
  end

  @doc "Reports the currently effective source for run list rollups."
  @spec list_runs_source(keyword()) :: %{source: atom(), confidence: String.t()}
  def list_runs_source(opts \\ []) do
    since = Keyword.get(opts, :since)
    client_id = Keyword.get(opts, :client_id)
    workspace = Keyword.get(opts, :workspace)

    with_rollup_cache(
      opts,
      {
        :trace_reader,
        :list_runs_source,
        normalize_cache_since(since),
        normalize_cache_scope(client_id),
        normalize_cache_scope(workspace),
        Keyword.get(opts, :traces_dir),
        Keyword.get(opts, :runs_dir)
      },
      @list_runs_source_cache_ttl_ms,
      fn -> do_list_runs_source(opts, since, client_id, workspace) end
    )
  rescue
    e in [
      DBConnection.ConnectionError,
      DBConnection.OwnershipError,
      Postgrex.Error,
      File.Error,
      ArgumentError
    ] ->
      require Logger
      Logger.warning("TraceReader.list_runs_source error: #{Exception.message(e)}")

      file_runs =
        file_list_runs(opts, Keyword.get(opts, :since))
        |> maybe_filter_runs_workspace(Keyword.get(opts, :workspace))

      if file_runs == [] do
        %{source: :empty, confidence: "low"}
      else
        %{source: :filesystem, confidence: "medium"}
      end
  end

  @doc "Groups trace events by phase for display. Infers phase from token_efficiency boundaries."
  @spec events_by_phase(String.t(), keyword()) :: %{String.t() => [map()]}
  def events_by_phase(run_id, opts \\ []) do
    events = events_for_run(run_id, Keyword.put(opts, :limit, 5000))
    group_events_by_phase(events)
  end

  @doc "Computes a detailed summary for a single run's trace events."
  @spec run_summary(String.t(), keyword()) :: map()
  def run_summary(run_id, opts \\ []) do
    events = events_for_run(run_id, Keyword.put(opts, :limit, 5000))

    manifest = run_manifest(run_id, opts)
    result = result_for_run(run_id, opts)

    phases = extract_phases(events) |> enrich_phases(manifest, result)
    tools = extract_tool_distribution(events)
    costs = extract_costs(events)
    files = extract_files(events)
    tasks = extract_tasks(events)
    agent_ids = events |> Enum.map(& &1["agentId"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    agent_info = extract_agents(events)

    # Get workflow name from manifest or result
    workflow_name =
      (manifest && manifest["workflow_name"]) ||
        (manifest && manifest["name"]) ||
        (result && result["workflow_name"]) ||
        run_id

    first_ts = List.first(events)
    last_ts = List.last(events)

    # Prefer result elapsed_ms if available (more accurate)
    duration_ms =
      cond do
        not is_nil(result) and is_number(result["elapsed_ms"]) and result["elapsed_ms"] > 0 ->
          result["elapsed_ms"]

        true ->
          with %{"timestamp" => t1} <- first_ts,
               %{"timestamp" => t2} <- last_ts,
               {:ok, d1, _} <- DateTime.from_iso8601(t1),
               {:ok, d2, _} <- DateTime.from_iso8601(t2) do
            DateTime.diff(d2, d1, :millisecond)
          else
            _ -> 0
          end
      end

    %{
      run_id: run_id,
      workflow_name: workflow_name,
      event_count: length(events),
      phase_count: length(phases),
      agent_count: max(length(agent_ids), length(agent_info.agents)),
      agents: agent_ids,
      agent_details: agent_info.agents,
      agent_spawn_count: agent_info.agent_spawn_count,
      duration_ms: duration_ms,
      phases: phases,
      tools: tools,
      costs: costs,
      files: files,
      tasks: tasks,
      total_cost_usd: Enum.reduce(costs, 0.0, &(&1.cost_usd + &2)),
      total_input_tokens: Enum.reduce(costs, 0, &(&1.input_tokens + &2)),
      total_output_tokens: Enum.reduce(costs, 0, &(&1.output_tokens + &2))
    }
  end

  @doc """
  Loads all trace data for a run in a single pass.

  Eliminates redundant calls: events_for_run is fetched once and reused
  for run_summary, events_by_phase, and the raw events list.  Lifecycle,
  transcripts, and MCP data are loaded in parallel via Task.async.

  Returns a map with keys: :summary, :events, :phase_events, :lifecycle,
  :transcripts, :mcp_events, :mcp_stats (any key may be nil/[] on error).
  """
  @spec detailed_run_view(String.t(), keyword()) :: map()
  def detailed_run_view(run_id, opts \\ []) do
    # Single event fetch — reused for summary + phase grouping
    events = events_for_run(run_id, Keyword.put(opts, :limit, 5000))

    # Derive summary from the already-loaded events (avoid re-fetching)
    summary = run_summary_from_events(run_id, events, opts)

    # Phase grouping from same events
    phase_events = group_events_by_phase(events)

    # Independent data loaded in parallel
    tasks = %{
      lifecycle: Task.async(fn -> lifecycle_agents(run_id, opts) end),
      transcripts: Task.async(fn -> agent_transcripts(run_id, opts) end),
      mcp_events: Task.async(fn -> mcp_tool_events(limit: 200) end)
    }

    results =
      Map.new(tasks, fn {k, task} ->
        try do
          {k, Task.await(task, 10_000)}
        catch
          :exit, _ ->
            Task.shutdown(task, :brutal_kill)
            {k, []}
        end
      end)

    mcp_stats = compute_mcp_stats(results.mcp_events)

    %{
      summary: summary,
      events: Enum.take(events, 1000),
      phase_events: phase_events,
      lifecycle: results.lifecycle,
      transcripts: results.transcripts,
      mcp_events: results.mcp_events,
      mcp_stats: mcp_stats
    }
  end

  # Like run_summary/2 but accepts pre-fetched events to avoid re-reading.
  defp run_summary_from_events(run_id, events, opts) do
    manifest = run_manifest(run_id, opts)
    result = result_for_run(run_id, opts)

    phases = extract_phases(events) |> enrich_phases(manifest, result)
    tools = extract_tool_distribution(events)
    costs = extract_costs(events)
    files = extract_files(events)
    tasks = extract_tasks(events)
    agent_ids = events |> Enum.map(& &1["agentId"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    agent_info = extract_agents(events)

    workflow_name =
      (manifest && manifest["workflow_name"]) ||
        (manifest && manifest["name"]) ||
        (result && result["workflow_name"]) ||
        run_id

    first_ts = List.first(events)
    last_ts = List.last(events)

    duration_ms =
      cond do
        not is_nil(result) and is_number(result["elapsed_ms"]) and result["elapsed_ms"] > 0 ->
          result["elapsed_ms"]

        true ->
          with %{"timestamp" => t1} <- first_ts,
               %{"timestamp" => t2} <- last_ts,
               {:ok, d1, _} <- DateTime.from_iso8601(t1),
               {:ok, d2, _} <- DateTime.from_iso8601(t2) do
            DateTime.diff(d2, d1, :millisecond)
          else
            _ -> 0
          end
      end

    %{
      run_id: run_id,
      workflow_name: workflow_name,
      event_count: length(events),
      phase_count: length(phases),
      agent_count: max(length(agent_ids), length(agent_info.agents)),
      agents: agent_ids,
      agent_details: agent_info.agents,
      agent_spawn_count: agent_info.agent_spawn_count,
      duration_ms: duration_ms,
      phases: phases,
      tools: tools,
      costs: costs,
      files: files,
      tasks: tasks,
      total_cost_usd: Enum.reduce(costs, 0.0, &(&1.cost_usd + &2)),
      total_input_tokens: Enum.reduce(costs, 0, &(&1.input_tokens + &2)),
      total_output_tokens: Enum.reduce(costs, 0, &(&1.output_tokens + &2))
    }
  end

  # Compute mcp_tool_stats from pre-fetched events (avoids re-reading the file).
  defp compute_mcp_stats(events) when is_list(events) do
    events
    |> Enum.group_by(& &1.tool)
    |> Enum.map(fn {tool, evts} ->
      succeeded = Enum.count(evts, &(&1.status == "success"))
      failed = Enum.count(evts, &(&1.status == "error"))
      denied = Enum.count(evts, &(&1.status == "denied"))

      durations =
        evts
        |> Enum.filter(&(&1.status == "success"))
        |> Enum.map(& &1.duration_ms)

      avg_duration =
        if durations != [] do
          Enum.sum(durations) / length(durations)
        else
          0
        end

      %{
        tool: tool,
        calls: length(evts),
        succeeded: succeeded,
        failed: failed,
        denied: denied,
        avg_duration_ms: Float.round(avg_duration * 1.0, 1),
        success_rate:
          if(succeeded + failed > 0,
            do: Float.round(succeeded / (succeeded + failed) * 100.0, 1),
            else: 100.0
          )
      }
    end)
    |> Enum.sort_by(& &1.calls, :desc)
  end

  defp compute_mcp_stats(_), do: []

  # ---------------------------------------------------------------------------
  # Private helpers for list_runs / run_summary
  # ---------------------------------------------------------------------------

  defp do_list_runs(opts, since, client_id, workspace) do
    case db_list_runs(since, client_id, workspace) do
      [] ->
        file_list_runs(opts, since)
        |> maybe_filter_runs_workspace(workspace)

      runs ->
        supplemental =
          if is_binary(client_id) and client_id != "" do
            []
          else
            file_runs = file_list_runs(opts, since, supplemental_only: true)
            existing_ids = MapSet.new(runs, & &1.run_id)
            Enum.reject(file_runs, &MapSet.member?(existing_ids, &1.run_id))
          end

        (runs ++ supplemental)
        |> maybe_filter_runs_workspace(workspace)
        |> Enum.reject(&ignored_rollup_run?/1)
        |> Enum.sort_by(&(&1.started_at || ""), :desc)
    end
  end

  defp do_list_runs_source(opts, since, client_id, workspace) do
    case db_list_runs(since, client_id, workspace) do
      [_ | _] ->
        %{source: :postgres, confidence: "high"}

      [] ->
        file_runs =
          file_list_runs(opts, since)
          |> maybe_filter_runs_workspace(workspace)

        if file_runs == [] do
          %{source: :empty, confidence: "low"}
        else
          %{source: :filesystem, confidence: "medium"}
        end
    end
  end

  defp file_events_for_run(run_id, opts) do
    limit = Keyword.get(opts, :limit, 500)
    traces_dir = Keyword.get(opts, :traces_dir, resolve_path(@traces_rel))
    path = Path.join(traces_dir, "#{run_id}.jsonl")

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&parse_line/1)
      |> Stream.reject(&is_nil/1)
      |> Enum.take(-limit)
    else
      []
    end
  end

  defp file_all_events(opts) do
    limit = Keyword.get(opts, :limit, 50)
    run_id = Keyword.get(opts, :run_id)
    traces_dir = Keyword.get(opts, :traces_dir, resolve_path(@traces_rel))

    if File.dir?(traces_dir) do
      files =
        if run_id do
          [Path.join(traces_dir, "#{run_id}.jsonl")]
          |> Enum.filter(&File.exists?/1)
        else
          traces_dir
          |> File.ls!()
          |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
          |> Enum.map(&Path.join(traces_dir, &1))
        end

      files
      |> Enum.flat_map(fn path ->
        path
        |> File.stream!()
        |> Stream.map(&parse_line/1)
        |> Stream.reject(&is_nil/1)
        |> Enum.to_list()
      end)
      |> Enum.take(-limit)
    else
      []
    end
  end

  defp file_run_manifest(run_id, opts) do
    runs_dir = Keyword.get(opts, :runs_dir, resolve_path(@runs_rel))
    path = Path.join(runs_dir, "#{run_id}.json")

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> data
          _ -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp file_list_runs(opts, since, extra_opts \\ []) do
    traces_dir = Keyword.get(opts, :traces_dir, resolve_path(@traces_rel))
    supplemental_only = Keyword.get(extra_opts, :supplemental_only, false)

    if File.dir?(traces_dir) do
      traces_dir
      |> File.ls!()
      |> Enum.filter(&valid_trace_filename?/1)
      |> Enum.map(&summarize_trace_file(Path.join(traces_dir, &1)))
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&ignored_file_run?/1)
      |> Enum.reject(&(supplemental_only and not fresh_file_only_run?(&1)))
      |> maybe_filter_runs_since(since)
      |> enrich_file_runs_with_transcript_tokens()
      |> Enum.sort_by(&(&1.started_at || ""), :desc)
      |> Enum.map(&strip_internal_file_fields/1)
    else
      []
    end
  end

  defp maybe_filter_runs_workspace(runs, nil), do: runs
  defp maybe_filter_runs_workspace(runs, ""), do: runs

  defp maybe_filter_runs_workspace(runs, workspace) when is_binary(workspace) do
    Enum.filter(runs, fn run ->
      Map.get(run, :workspace_path) == workspace
    end)
  end

  defp maybe_filter_runs_workspace(runs, _), do: runs

  defp db_events_for_run(run_id, limit) do
    TraceEvent
    |> where([e], e.run_id == ^run_id)
    |> order_by([e], desc: e.timestamp)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map(&trace_event_to_map/1)
  end

  defp db_all_events(limit, nil) do
    TraceEvent
    |> order_by([e], desc: e.timestamp)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map(&trace_event_to_map/1)
  end

  defp db_all_events(limit, run_id), do: db_events_for_run(run_id, limit)

  defp db_run_manifest(run_id) do
    case Repo.get(WorkflowRun, run_id) do
      nil -> nil
      %WorkflowRun{} = run -> workflow_run_to_manifest(run)
    end
  end

  defp db_list_runs(since, client_id, workspace) do
    query =
      WorkflowRun
      |> maybe_filter_workflow_runs_since(since)
      |> maybe_filter_workflow_runs_client(client_id)
      |> maybe_filter_workflow_runs_workspace(workspace)
      |> order_by([r], desc: r.updated_at)

    runs =
      query
      |> Repo.all()
      |> Enum.reject(&ignored_db_run?/1)

    if runs == [] do
      []
    else
      run_ids = Enum.map(runs, & &1.run_id)

      # Parallelize 3 independent DB queries — same table, same WHERE, different aggregations
      counts_task = Task.async(fn -> trace_event_counts(run_ids) end)
      rollups_task = Task.async(fn -> trace_event_rollups(run_ids) end)
      terminal_task = Task.async(fn -> trace_event_terminal_rollups(run_ids) end)

      event_counts = Task.await(counts_task, 10_000)
      rollups = Task.await(rollups_task, 10_000)
      terminal_rollups = Task.await(terminal_task, 10_000)

      runs
      |> Enum.map(fn run ->
        terminal = Map.get(terminal_rollups, run.run_id, %{})
        event_count = Map.get(event_counts, run.run_id, 0)

        rollup =
          Map.get(rollups, run.run_id, %{input_tokens: 0, output_tokens: 0, total_cost_usd: 0.0})

        terminal_status =
          canonical_run_status(
            run,
            Map.get(terminal, :status, normalize_run_status(run.status)),
            event_count
          )

        ended_at_dt =
          effective_run_ended_at(terminal_status, terminal[:ended_at_dt], run.updated_at)

        %{
          run_id: run.run_id,
          started_at: iso8601(run.created_at),
          ended_at: iso8601(ended_at_dt),
          event_count: event_count,
          status: terminal_status,
          workflow_name: run.workflow_name || run.run_id,
          workspace_path: run.workspace_path,
          task_description: run.task_description,
          execution_type: run.execution_type || "subscription",
          client_id: run.client_id,
          phase_count: length(run.phases || []),
          duration_ms:
            effective_run_duration_ms(
              run.created_at,
              ended_at_dt,
              run.updated_at,
              terminal[:duration_ms]
            ),
          total_input_tokens: rollup.input_tokens,
          total_output_tokens: rollup.output_tokens,
          total_tokens: rollup.input_tokens + rollup.output_tokens,
          total_cost_usd: rollup.total_cost_usd
        }
      end)
      |> Enum.reject(&ignored_rollup_run?/1)
      |> Enum.sort_by(&(&1.started_at || ""), :desc)
    end
  end

  defp maybe_filter_workflow_runs_since(query, nil), do: query

  defp maybe_filter_workflow_runs_since(query, %DateTime{} = since) do
    where(query, [r], r.created_at >= ^since)
  end

  defp maybe_filter_workflow_runs_since(query, _), do: query

  defp maybe_filter_workflow_runs_client(query, nil), do: query
  defp maybe_filter_workflow_runs_client(query, ""), do: query

  defp maybe_filter_workflow_runs_client(query, client_id) when is_binary(client_id) do
    where(query, [r], r.client_id == ^client_id)
  end

  defp maybe_filter_workflow_runs_client(query, _), do: query

  defp maybe_filter_workflow_runs_workspace(query, nil), do: query
  defp maybe_filter_workflow_runs_workspace(query, ""), do: query

  defp maybe_filter_workflow_runs_workspace(query, workspace) when is_binary(workspace) do
    where(query, [r], r.workspace_path == ^workspace)
  end

  defp maybe_filter_workflow_runs_workspace(query, _), do: query

  defp trace_event_counts([]), do: %{}

  defp trace_event_counts(run_ids) do
    TraceEvent
    |> where([e], e.run_id in ^run_ids)
    |> group_by([e], e.run_id)
    |> select([e], {e.run_id, count(e.trace_id)})
    |> Repo.all()
    |> Map.new(fn {run_id, count} -> {run_id, count} end)
  end

  defp trace_event_rollups([]), do: %{}

  defp trace_event_rollups(run_ids) do
    TraceEvent
    |> where([e], e.run_id in ^run_ids)
    |> group_by([e], e.run_id)
    |> select([e], {
      e.run_id,
      sum(
        fragment(
          "CASE WHEN ? = 'token_efficiency' THEN COALESCE((?->>'inputTokens')::bigint, (?->>'input_tokens')::bigint, 0) ELSE 0 END",
          e.event_type,
          e.metadata,
          e.metadata
        )
      ),
      sum(
        fragment(
          "CASE WHEN ? = 'token_efficiency' THEN COALESCE((?->>'outputTokens')::bigint, (?->>'output_tokens')::bigint, 0) ELSE 0 END",
          e.event_type,
          e.metadata,
          e.metadata
        )
      ),
      sum(
        fragment(
          "CASE WHEN ? = 'token_efficiency' THEN COALESCE((?->>'costUsd')::double precision, (?->>'cost_usd')::double precision, 0) ELSE 0 END",
          e.event_type,
          e.metadata,
          e.metadata
        )
      ),
      sum(
        fragment(
          "COALESCE((?->>'inputTokens')::bigint, (?->>'input_tokens')::bigint, 0)",
          e.metadata,
          e.metadata
        )
      ),
      sum(
        fragment(
          "COALESCE((?->>'outputTokens')::bigint, (?->>'output_tokens')::bigint, 0)",
          e.metadata,
          e.metadata
        )
      ),
      sum(
        fragment(
          "COALESCE((?->>'costUsd')::double precision, (?->>'cost_usd')::double precision, 0)",
          e.metadata,
          e.metadata
        )
      )
    })
    |> Repo.all()
    |> Map.new(fn {run_id, eff_input, eff_output, eff_cost, all_input, all_output, all_cost} ->
      input_tokens = choose_rollup_value(eff_input, all_input)
      output_tokens = choose_rollup_value(eff_output, all_output)
      total_cost_usd = choose_rollup_float(eff_cost, all_cost)

      {run_id,
       %{
         input_tokens: safe_int(input_tokens),
         output_tokens: safe_int(output_tokens),
         total_cost_usd: safe_float(total_cost_usd)
       }}
    end)
  end

  defp choose_rollup_value(primary, fallback) do
    primary_int = safe_int(primary)

    if primary_int > 0 do
      primary_int
    else
      safe_int(fallback)
    end
  end

  defp choose_rollup_float(primary, fallback) do
    primary_float = safe_float(primary)

    if primary_float > 0 do
      primary_float
    else
      safe_float(fallback)
    end
  end

  defp trace_event_terminal_rollups([]), do: %{}

  defp trace_event_terminal_rollups(run_ids) do
    TraceEvent
    |> where(
      [e],
      e.run_id in ^run_ids and
        e.event_type in ["checkpoint", "phase_end", "token_efficiency", "verify_pass"]
    )
    |> order_by([e], asc: e.run_id, desc: e.timestamp)
    |> select([e], {e.run_id, e.timestamp, e.event_type, e.metadata})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {run_id, timestamp, event_type, metadata}, acc ->
      if Map.has_key?(acc, run_id) do
        acc
      else
        status = file_event_status(%{"eventType" => event_type, "metadata" => metadata || %{}})

        if terminal_status?(status) do
          Map.put(acc, run_id, %{
            status: status,
            ended_at_dt: timestamp,
            duration_ms: metadata_duration_ms(metadata)
          })
        else
          acc
        end
      end
    end)
  end

  defp workflow_run_to_manifest(%WorkflowRun{} = run) do
    %{
      "run_id" => run.run_id,
      "card_id" => run.card_id,
      "workflow_name" => run.workflow_name,
      "workspace_path" => run.workspace_path,
      "workspacePath" => run.workspace_path,
      "task_description" => run.task_description,
      "status" => run.status,
      "execution_type" => run.execution_type,
      "plan_note" => run.plan_note,
      "plan_summary" => run.plan_summary,
      "createdAt" => iso8601(run.created_at),
      "updatedAt" => iso8601(run.updated_at),
      "phases" => Enum.map(run.phases || [], &normalize_phase/1)
    }
  end

  defp normalize_phase(phase) do
    name = phase["phaseName"] || phase["name"] || phase["id"] || "unknown"

    %{
      "id" => phase["id"] || phase["phaseId"] || name,
      "name" => name,
      "phaseName" => name,
      "type" => phase["type"] || "session",
      "status" => phase["status"] || "pending",
      "phaseIndex" => phase["phaseIndex"] || phase["phase_index"] || 0,
      "sessionId" => phase["sessionId"] || phase["session_id"],
      "agents" => phase["agents"] || []
    }
  end

  defp trace_event_to_map(%TraceEvent{} = event) do
    %{
      "timestamp" => iso8601(event.timestamp),
      "traceId" => event.trace_id,
      "runId" => event.run_id,
      "phaseId" => event.phase_id,
      "agentId" => event.agent_id,
      "sessionId" => event.session_id,
      "eventType" => event.event_type,
      "tool" => event.tool,
      "detail" => event.detail,
      "metadata" => event.metadata || %{}
    }
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp iso8601(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp iso8601(other) when is_binary(other), do: other

  defp summarize_trace_file(path) do
    run_id = path |> Path.basename(".jsonl")

    if ignored_trace_run_id?(run_id) do
      nil
    else
      summary =
        path
        |> File.stream!()
        |> Enum.reduce(empty_file_trace_summary(run_id), fn line, acc ->
          case parse_line(line) do
            nil ->
              acc

            event ->
              update_file_trace_summary(acc, event)
          end
        end)

      build_file_trace_run(summary)
    end
  rescue
    e in [File.Error, Jason.DecodeError] ->
      require Logger

      Logger.warning(
        "TraceReader.summarize_trace_file error for #{path}: #{Exception.message(e)}"
      )

      nil
  end

  defp valid_trace_filename?(filename) do
    String.ends_with?(filename, ".jsonl") and
      not String.contains?(filename, ".jsonl.") and
      filename != "unscoped.jsonl"
  end

  defp ignored_trace_run_id?(run_id) when is_binary(run_id) do
    run_id == "unscoped" or
      String.starts_with?(run_id, "test-run-") or
      String.starts_with?(run_id, "test-") or
      String.starts_with?(run_id, "trace-timeline-run") or
      String.contains?(String.downcase(run_id), "test") or
      String.starts_with?(run_id, "nonexistent-run")
  end

  defp ignored_trace_run_id?(_), do: false

  defp fresh_file_only_run?(run) do
    case parse_iso8601_ms(run.ended_at || run.started_at) do
      nil ->
        false

      timestamp_ms ->
        System.system_time(:millisecond) - timestamp_ms <= @supplemental_file_max_age_ms
    end
  end

  defp ignored_file_run?(run) do
    run.event_count == 0 or
      ignored_trace_run_id?(run.run_id) or
      test_task_description?(run.task_description) or
      orphaned_deleted_card_run?(run) or
      ignored_rollup_run?(run)
  end

  defp ignored_db_run?(%WorkflowRun{} = run) do
    ignored_trace_run_id?(run.run_id) or
      test_task_description?(run.task_description) or
      synthetic_workflow_name?(run.workflow_name)
  end

  defp test_task_description?(description) when is_binary(description) do
    lower = String.downcase(description)

    Enum.any?(
      ["test task", "synthetic", "smoke test", "dummy run", "debug run", "test trace"],
      &String.contains?(lower, &1)
    )
  end

  defp test_task_description?(_), do: false

  defp synthetic_workflow_name?(name) when is_binary(name) do
    lower = String.downcase(name)
    String.contains?(lower, "test") or String.contains?(lower, "synthetic")
  end

  defp synthetic_workflow_name?(_), do: false

  defp ignored_rollup_run?(run) when is_map(run) do
    event_count = Map.get(run, :event_count, 0)
    total_tokens = Map.get(run, :total_tokens, 0)
    total_cost_usd = Map.get(run, :total_cost_usd, 0.0)

    synthetic = ignored_trace_run_id?(Map.get(run, :run_id, ""))

    suspicious_large =
      event_count >= @pathological_event_count and total_tokens == 0 and total_cost_usd == 0

    synthetic or suspicious_large
  end

  defp ignored_rollup_run?(_), do: false

  defp orphaned_deleted_card_run?(run) when is_map(run) do
    Map.get(run, :status) == "orphaned" and Map.get(run, :orphaned_card_deleted, false)
  end

  defp orphaned_deleted_card_run?(_), do: false

  defp strip_internal_file_fields(run) when is_map(run) do
    run
    |> Map.delete(:session_ids)
    |> Map.delete(:orphaned_card_deleted)
  end

  defp strip_internal_file_fields(run), do: run

  defp empty_file_trace_summary(run_id) do
    %{
      run_id: run_id,
      first_event: nil,
      last_event: nil,
      event_count: 0,
      workflow_name: nil,
      workspace_path: nil,
      task_description: nil,
      phase_ids: MapSet.new(),
      session_ids: MapSet.new(),
      orphaned_card_deleted: false,
      status: nil,
      total_input_tokens: 0,
      total_output_tokens: 0,
      total_cost_usd: 0.0,
      token_duration_ms: 0
    }
  end

  defp update_file_trace_summary(acc, event) do
    metadata = event["metadata"] || %{}
    terminal_status = file_event_status(event)
    task_description = extract_task_description(acc.task_description, event)
    phase_ids = maybe_add_phase_id(acc.phase_ids, event["phaseId"])
    session_ids = maybe_add_session_id(acc.session_ids, event["sessionId"] || event["session_id"])
    input_tokens = safe_int(metadata["inputTokens"] || metadata["input_tokens"])
    output_tokens = safe_int(metadata["outputTokens"] || metadata["output_tokens"])
    cost_usd = safe_float(metadata["costUsd"] || metadata["cost_usd"])

    %{
      acc
      | first_event: acc.first_event || event,
        last_event: event,
        event_count: acc.event_count + 1,
        workflow_name: extract_workflow_name(acc.workflow_name, event),
        workspace_path: extract_workspace_path(acc.workspace_path, event),
        task_description: task_description,
        phase_ids: phase_ids,
        session_ids: session_ids,
        orphaned_card_deleted: acc.orphaned_card_deleted or orphaned_card_deleted_event?(event),
        status: terminal_status || acc.status,
        total_input_tokens: acc.total_input_tokens + input_tokens,
        total_output_tokens: acc.total_output_tokens + output_tokens,
        total_cost_usd: acc.total_cost_usd + cost_usd,
        token_duration_ms: acc.token_duration_ms + metadata_duration_ms(metadata)
    }
  end

  defp build_file_trace_run(%{event_count: 0}), do: nil

  defp build_file_trace_run(summary) do
    started_at = get_in(summary, [:first_event, "timestamp"])
    ended_at = get_in(summary, [:last_event, "timestamp"])
    inferred_status = infer_file_run_status(summary)

    %{
      run_id: summary.run_id,
      started_at: started_at,
      ended_at: ended_at,
      event_count: summary.event_count,
      status: inferred_status,
      workflow_name: summary.workflow_name || summary.run_id,
      workspace_path: summary.workspace_path,
      task_description: summary.task_description,
      phase_count: MapSet.size(summary.phase_ids),
      duration_ms: file_run_duration_ms(started_at, ended_at, summary.token_duration_ms),
      total_input_tokens: summary.total_input_tokens,
      total_output_tokens: summary.total_output_tokens,
      total_tokens: summary.total_input_tokens + summary.total_output_tokens,
      total_cost_usd: summary.total_cost_usd,
      session_ids: MapSet.to_list(summary.session_ids),
      orphaned_card_deleted: summary.orphaned_card_deleted
    }
  end

  defp extract_workflow_name(existing, event) do
    existing ||
      event["workflowName"] ||
      get_in(event, ["metadata", "workflow"]) ||
      get_in(event, ["metadata", "workflowName"])
  end

  defp extract_workspace_path(existing, event) do
    existing ||
      event["workspacePath"] ||
      event["workspace_path"] ||
      event["project"] ||
      get_in(event, ["metadata", "workspacePath"]) ||
      get_in(event, ["metadata", "workspace_path"]) ||
      get_in(event, ["metadata", "workspace"]) ||
      get_in(event, ["metadata", "project"])
  end

  defp extract_task_description(nil, %{"tool" => "TaskCreate", "detail" => detail})
       when is_binary(detail) and detail != "",
       do: detail

  defp extract_task_description(existing, _event), do: existing

  defp maybe_add_phase_id(phase_ids, phase_id) when is_binary(phase_id),
    do: MapSet.put(phase_ids, phase_id)

  defp maybe_add_phase_id(phase_ids, _), do: phase_ids

  defp maybe_add_session_id(session_ids, session_id)
       when is_binary(session_id) and session_id != "",
       do: MapSet.put(session_ids, session_id)

  defp maybe_add_session_id(session_ids, _), do: session_ids

  defp orphaned_card_deleted_event?(%{"metadata" => metadata, "detail" => detail})
       when is_map(metadata) do
    metadata["stage"] == "run_orphaned" and
      (is_nil(metadata["cardId"]) or detail == "Run orphaned because card was deleted")
  end

  defp orphaned_card_deleted_event?(_), do: false

  defp infer_file_run_status(summary) do
    cond do
      is_binary(summary.status) ->
        normalize_run_status(summary.status)

      stale_trace?(summary.last_event) and completed_file_run?(summary) ->
        "done"

      stale_trace?(summary.last_event) ->
        "orphaned"

      true ->
        "running"
    end
  end

  defp completed_file_run?(summary) do
    summary.event_count > 0 and
      (summary.total_input_tokens > 0 or
         summary.total_output_tokens > 0 or
         summary.total_cost_usd > 0 or
         MapSet.size(summary.phase_ids) > 0)
  end

  defp enrich_file_runs_with_transcript_tokens([]), do: []

  defp enrich_file_runs_with_transcript_tokens(runs) do
    candidates =
      Enum.filter(runs, fn run ->
        safe_int(Map.get(run, :total_tokens, 0)) <= 0 and
          is_list(Map.get(run, :session_ids)) and Map.get(run, :session_ids) != []
      end)

    if candidates == [] do
      runs
    else
      session_ids =
        candidates
        |> Enum.flat_map(&Map.get(&1, :session_ids, []))
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()

      usage_by_session = session_usage_by_id(session_ids)

      Enum.map(runs, fn run ->
        existing_total_tokens = safe_int(Map.get(run, :total_tokens, 0))

        if existing_total_tokens > 0 do
          run
        else
          %{input_tokens: input_tokens, output_tokens: output_tokens} =
            transcript_token_totals_for_run(run, usage_by_session)

          run
          |> Map.put(:total_input_tokens, safe_int(input_tokens))
          |> Map.put(:total_output_tokens, safe_int(output_tokens))
          |> Map.put(:total_tokens, safe_int(input_tokens) + safe_int(output_tokens))
        end
      end)
    end
  end

  defp session_usage_by_id([]), do: %{}

  defp session_usage_by_id(session_ids) do
    summary =
      LLMUsageReader.build_summary(
        extra_session_ids: session_ids,
        include_subscription: true,
        session_limit: length(session_ids),
        cache: true
      )

    (summary["sessions"] || [])
    |> Enum.reduce(%{}, fn session, acc ->
      session_id = session["sessionId"]

      if is_binary(session_id) and session_id != "" do
        Map.put(acc, session_id, %{
          input_tokens: safe_int(session["inputTokens"]),
          output_tokens: safe_int(session["outputTokens"])
        })
      else
        acc
      end
    end)
  rescue
    e in [DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] ->
      require Logger
      Logger.warning("TraceReader.session_usage_by_id error: #{Exception.message(e)}")
      %{}
  end

  defp transcript_token_totals_for_run(run, usage_by_session) do
    run
    |> Map.get(:session_ids, [])
    |> Enum.reduce(%{input_tokens: 0, output_tokens: 0}, fn session_id, acc ->
      usage = Map.get(usage_by_session, session_id, %{input_tokens: 0, output_tokens: 0})

      %{
        input_tokens: acc.input_tokens + safe_int(usage.input_tokens),
        output_tokens: acc.output_tokens + safe_int(usage.output_tokens)
      }
    end)
  end

  defp canonical_run_status(%WorkflowRun{} = run, terminal_status, event_count) do
    base_status = normalize_run_status(run.status)

    cond do
      terminal_status?(terminal_status) ->
        terminal_status

      terminal_status?(base_status) ->
        base_status

      base_status in ["running", "pending"] and event_count > 0 and
          stale_workflow_run?(run.updated_at) ->
        "done"

      base_status == "review" and event_count > 0 and stale_workflow_run?(run.updated_at) ->
        "done"

      true ->
        base_status
    end
  end

  defp stale_workflow_run?(%DateTime{} = updated_at) do
    DateTime.diff(DateTime.utc_now(), updated_at, :millisecond) > @stale_running_ms
  end

  defp stale_workflow_run?(%NaiveDateTime{} = updated_at) do
    updated_at
    |> DateTime.from_naive!("Etc/UTC")
    |> stale_workflow_run?()
  end

  defp stale_workflow_run?(_), do: false

  defp stale_trace?(nil), do: false

  defp stale_trace?(event) do
    case parse_iso8601_ms(event["timestamp"]) do
      nil ->
        false

      timestamp_ms ->
        System.system_time(:millisecond) - timestamp_ms > @supplemental_file_max_age_ms
    end
  end

  defp file_event_status(%{"metadata" => %{"stage" => stage}}) do
    case stage do
      "run_completed" -> "done"
      "run_done" -> "done"
      "run_failed" -> "failed"
      "run_cancelled" -> "cancelled"
      "run_orphaned" -> "orphaned"
      _ -> nil
    end
  end

  defp file_event_status(%{"metadata" => %{"runStatus" => status}}),
    do: normalize_run_status(status)

  defp file_event_status(%{"metadata" => %{"to" => status}}), do: normalize_run_status(status)

  defp file_event_status(%{"eventType" => "phase_end", "metadata" => %{"status" => status}}) do
    normalize_run_status(status)
  end

  defp file_event_status(%{"eventType" => "verify_pass", "metadata" => %{"status" => status}}) do
    normalize_run_status(status)
  end

  defp file_event_status(%{"eventType" => "phase_end"}), do: "done"

  defp file_event_status(%{"eventType" => "token_efficiency", "metadata" => metadata}) do
    result = metadata["result"]
    exit_code = metadata["exit_code"]

    cond do
      result in ["done", "completed", "success"] -> "done"
      result == "orphaned" -> "orphaned"
      result in ["failed", "timeout", "error"] -> "failed"
      is_number(exit_code) and exit_code == 0 -> "done"
      is_number(exit_code) and exit_code != 0 -> "failed"
      true -> nil
    end
  end

  defp file_event_status(_), do: nil

  defp normalize_run_status(status) when status in ["completed", "done"], do: "done"
  defp normalize_run_status(status) when status in ["in_progress", "review"], do: "running"

  defp normalize_run_status(status)
       when status in ["pending", "running", "failed", "cancelled", "orphaned", "budget_paused"],
       do: status

  defp normalize_run_status(status) when is_binary(status), do: status
  defp normalize_run_status(_), do: "unknown"

  defp effective_run_ended_at(_status, %DateTime{} = ended_at_dt, _updated_at), do: ended_at_dt

  defp effective_run_ended_at(status, nil, updated_at) do
    if terminal_status?(status), do: updated_at, else: nil
  end

  defp effective_run_ended_at(_, _, _), do: nil

  defp effective_run_duration_ms(
         created_at,
         %DateTime{} = ended_at_dt,
         _updated_at,
         duration_ms
       ) do
    computed = run_duration_ms(created_at, ended_at_dt)
    if computed > 0, do: computed, else: max(safe_int(duration_ms), 0)
  end

  defp effective_run_duration_ms(
         created_at,
         %NaiveDateTime{} = ended_at_dt,
         _updated_at,
         duration_ms
       ) do
    computed = run_duration_ms(created_at, ended_at_dt)
    if computed > 0, do: computed, else: max(safe_int(duration_ms), 0)
  end

  defp effective_run_duration_ms(created_at, nil, updated_at, duration_ms) do
    computed = run_duration_ms(created_at, updated_at)
    if computed > 0, do: computed, else: max(safe_int(duration_ms), 0)
  end

  defp terminal_status?(status) when status in ["done", "failed", "cancelled", "orphaned"],
    do: true

  defp terminal_status?(_), do: false

  defp run_duration_ms(%DateTime{} = created_at, %DateTime{} = updated_at) do
    max(DateTime.diff(updated_at, created_at, :millisecond), 0)
  end

  defp run_duration_ms(%NaiveDateTime{} = created_at, %NaiveDateTime{} = updated_at) do
    created_at
    |> DateTime.from_naive!("Etc/UTC")
    |> run_duration_ms(DateTime.from_naive!(updated_at, "Etc/UTC"))
  end

  defp run_duration_ms(_, _), do: 0

  defp file_run_duration_ms(started_at, ended_at, fallback_duration_ms) do
    case {parse_iso8601_ms(started_at), parse_iso8601_ms(ended_at)} do
      {start_ms, end_ms} when is_integer(start_ms) and is_integer(end_ms) ->
        Enum.max([end_ms - start_ms, fallback_duration_ms, 0])

      _ ->
        max(fallback_duration_ms, 0)
    end
  end

  defp parse_iso8601_ms(nil), do: nil

  defp parse_iso8601_ms(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp safe_int(value) when is_integer(value), do: value
  defp safe_int(value) when is_float(value), do: trunc(value)
  defp safe_int(%Decimal{} = value), do: Decimal.to_integer(value)
  defp safe_int(nil), do: 0

  defp safe_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> 0
    end
  end

  defp safe_int(_), do: 0

  defp safe_float(value) when is_float(value), do: value
  defp safe_float(value) when is_integer(value), do: value * 1.0
  defp safe_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp safe_float(nil), do: 0.0

  defp safe_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> 0.0
    end
  end

  defp safe_float(_), do: 0.0

  defp with_rollup_cache(opts, key, ttl_ms, fun) do
    if Keyword.get(opts, :cache, @cache_enabled_default) do
      RollupCache.fetch(key, ttl_ms, fun)
    else
      fun.()
    end
  end

  defp normalize_cache_since(%DateTime{} = since), do: DateTime.to_iso8601(since)
  defp normalize_cache_since(%NaiveDateTime{} = since), do: NaiveDateTime.to_iso8601(since)
  defp normalize_cache_since(value), do: value

  defp normalize_cache_scope(nil), do: :all
  defp normalize_cache_scope(""), do: :all
  defp normalize_cache_scope(value) when is_binary(value), do: value
  defp normalize_cache_scope(value), do: value

  defp extract_phases(events) do
    # Keep the LAST start per phase_id (the successful retry attempt, not the
    # first attempt that may have failed). Group by phaseId, take last from each.
    starts =
      events
      |> Enum.filter(&(&1["eventType"] == "phase_start"))
      |> Enum.group_by(& &1["phaseId"])
      |> Enum.map(fn {_id, group} -> List.last(group) end)
      |> Enum.sort_by(&phase_index_from_id(&1["phaseId"]))

    if starts != [] do
      extract_phases_from_start_end(events, starts)
    else
      # Fallback: synthesize phases from token_efficiency events
      synthesize_phases_from_costs(events)
    end
  end

  defp extract_phases_from_start_end(events, starts) do
    # Map.new keeps last occurrence — which is the latest end for each phase.
    # This matches our last-start approach: both use the final retry attempt.
    ends = Enum.filter(events, &(&1["eventType"] == "phase_end"))
    end_map = Map.new(ends, &{&1["phaseId"], &1})

    phases =
      Enum.map(starts, fn s ->
        phase_id = s["phaseId"]
        e = Map.get(end_map, phase_id)
        meta = s["metadata"] || %{}
        end_meta = if is_map(e), do: e["metadata"] || %{}, else: %{}

        status =
          if e do
            normalize_run_status(end_meta["status"] || end_meta["runStatus"] || "done")
          else
            "running"
          end

        %{
          phase_id: phase_id,
          name: s["detail"] || phase_id,
          started_at: s["timestamp"],
          ended_at: e && e["timestamp"],
          status: status,
          agents: meta["agents"] || [],
          phase_type: meta["phaseType"]
        }
      end)

    # Rebase timestamps to show contiguous execution (collapse retry gaps).
    # Each phase starts immediately after the previous one ends.
    rebase_phase_timestamps(phases)
  end

  # Collapse idle gaps between phases so the timeline shows only active execution.
  # The first phase keeps its original start; subsequent phases are rebased to
  # start immediately after the previous phase's end.
  defp rebase_phase_timestamps([]), do: []

  defp rebase_phase_timestamps([first | rest]) do
    {rebased, _} =
      Enum.map_reduce(rest, first, fn phase, prev ->
        rebased_start = prev.ended_at || phase.started_at
        duration = phase_duration_ms(phase)

        rebased_end =
          if duration > 0 and rebased_start,
            do: shift_iso(rebased_start, duration),
            else: phase.ended_at

        rebased_phase = %{phase | started_at: rebased_start, ended_at: rebased_end}
        {rebased_phase, rebased_phase}
      end)

    [first | rebased]
  end

  defp phase_duration_ms(%{started_at: s, ended_at: e}) when is_binary(s) and is_binary(e) do
    with {:ok, s_dt, _} <- DateTime.from_iso8601(s),
         {:ok, e_dt, _} <- DateTime.from_iso8601(e) do
      max(DateTime.diff(e_dt, s_dt, :millisecond), 0)
    else
      _ -> 0
    end
  end

  defp phase_duration_ms(_), do: 0

  defp shift_iso(iso_string, add_ms) when is_binary(iso_string) and is_integer(add_ms) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> DateTime.add(dt, add_ms, :millisecond) |> DateTime.to_iso8601()
      _ -> iso_string
    end
  end

  defp shift_iso(iso_string, _), do: iso_string

  # Extract numeric phase index from phaseId like "run123-p0" → 0
  defp phase_index_from_id(nil), do: 0

  defp phase_index_from_id(phase_id) when is_binary(phase_id) do
    case Regex.run(~r/-p(\d+)$/, phase_id) do
      [_, idx] -> String.to_integer(idx)
      _ -> 0
    end
  end

  defp synthesize_phases_from_costs(events) do
    events
    |> Enum.filter(&(&1["eventType"] == "token_efficiency" and is_binary(&1["phaseId"])))
    |> Enum.uniq_by(& &1["phaseId"])
    |> Enum.map(fn e ->
      meta = e["metadata"] || %{}
      phase_id = e["phaseId"]
      duration_ms = meta["duration_ms"] || 0
      status = if meta["exit_code"] == 0, do: "done", else: "failed"

      ended_at = e["timestamp"]

      started_at =
        with ts when is_binary(ts) <- ended_at,
             {:ok, dt, _} <- DateTime.from_iso8601(ts) do
          dt |> DateTime.add(-duration_ms, :millisecond) |> DateTime.to_iso8601()
        else
          _ -> nil
        end

      %{
        phase_id: phase_id,
        name: phase_id,
        started_at: started_at,
        ended_at: ended_at,
        status: status,
        agents: [],
        phase_type: nil
      }
    end)
    |> Enum.sort_by(&(&1.started_at || ""))
  end

  defp extract_tool_distribution(events) do
    events
    |> Enum.filter(&(&1["eventType"] == "tool_call" and is_binary(&1["tool"])))
    |> Enum.frequencies_by(& &1["tool"])
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  defp extract_costs(events) do
    # Extract from token_efficiency events (API adapter)
    token_costs =
      events
      |> Enum.filter(&(&1["eventType"] == "token_efficiency"))
      |> Enum.map(fn e ->
        meta = e["metadata"] || %{}
        fresh_input = safe_int(meta["inputTokens"] || meta["input_tokens"])
        cache_read = safe_int(meta["cacheReadTokens"] || meta["cache_read_tokens"])

        %{
          phase_id: e["phaseId"],
          input_tokens: fresh_input + cache_read,
          output_tokens: safe_int(meta["outputTokens"] || meta["output_tokens"]),
          cost_usd: safe_float(meta["costUsd"] || meta["cost_usd"]),
          duration_ms: metadata_duration_ms(meta),
          cache_read_tokens: cache_read
        }
      end)

    # Extract from phase_end events with structuredOutput (SDK adapter)
    sdk_costs =
      events
      |> Enum.filter(fn e ->
        e["eventType"] == "phase_end" and
          get_in(e, ["metadata", "adapter"]) == "agent_sdk" and
          get_in(e, ["metadata", "structuredOutput", "cost"]) != nil
      end)
      |> Enum.map(fn e ->
        meta = e["metadata"] || %{}
        so = meta["structuredOutput"] || %{}
        cost = so["cost"] || %{}

        fresh_input = safe_int(cost["inputTokens"] || cost["input_tokens"] || 0)
        cache_read = safe_int(cost["cacheReadTokens"] || 0)

        %{
          phase_id: e["phaseId"],
          input_tokens: fresh_input + cache_read,
          output_tokens: safe_int(cost["outputTokens"] || cost["output_tokens"] || 0),
          cost_usd: safe_float(cost["totalUsd"] || cost["total_usd"] || 0),
          duration_ms: safe_int(so["durationMs"] || meta["durationMs"] || 0),
          cache_read_tokens: cache_read,
          cache_creation_tokens: safe_int(cost["cacheCreationTokens"] || 0)
        }
      end)

    # Deduplicate by phase_id — prefer SDK phase_end (has cost data) over token_efficiency
    all = token_costs ++ sdk_costs
    sdk_phase_ids = MapSet.new(sdk_costs, & &1.phase_id)

    all
    |> Enum.reject(fn c ->
      c.cost_usd == 0 and MapSet.member?(sdk_phase_ids, c.phase_id)
    end)
  end

  defp metadata_duration_ms(metadata) when is_map(metadata) do
    (metadata["totalRunMs"] || metadata["durationMs"] || metadata["duration_ms"])
    |> safe_int()
  end

  defp metadata_duration_ms(_), do: 0

  defp extract_files(events) do
    # From phase_completed events (flat metadata)
    flat_files =
      events
      |> Enum.filter(&(&1["eventType"] == "phase_completed"))
      |> Enum.flat_map(fn e ->
        meta = e["metadata"] || %{}
        phase_id = e["phaseId"]
        modified = meta["filesModified"] || []
        created = meta["filesCreated"] || []

        Enum.map(modified, &%{file: &1, action: "modified", phase_id: phase_id}) ++
          Enum.map(created, &%{file: &1, action: "created", phase_id: phase_id})
      end)

    # From phase_end events with structuredOutput (SDK adapter)
    sdk_files =
      events
      |> Enum.filter(fn e ->
        e["eventType"] == "phase_end" and
          get_in(e, ["metadata", "structuredOutput", "execution"]) != nil
      end)
      |> Enum.flat_map(fn e ->
        phase_id = e["phaseId"]
        exec = get_in(e, ["metadata", "structuredOutput", "execution"]) || %{}
        modified = exec["filesModified"] || []
        created = exec["filesCreated"] || []

        Enum.map(modified, &%{file: &1, action: "modified", phase_id: phase_id}) ++
          Enum.map(created, &%{file: &1, action: "created", phase_id: phase_id})
      end)

    (flat_files ++ sdk_files) |> Enum.uniq_by(&{&1.file, &1.action})
  end

  defp extract_tasks(events) do
    events
    |> Enum.filter(
      &(&1["eventType"] == "tool_call" and &1["tool"] in ["TaskCreate", "TaskUpdate"])
    )
    |> Enum.map(fn e ->
      %{
        tool: e["tool"],
        detail: e["detail"] || "",
        timestamp: e["timestamp"]
      }
    end)
  end

  # Enrich phases with names from the run manifest and durations from result
  defp enrich_phases(phases, nil, _result), do: phases

  defp enrich_phases(phases, manifest, result) do
    manifest_phases = manifest["phases"] || []
    result_phases = (result && result["phases"]) || []

    result_status =
      normalize_optional_status(result && (result["status"] || result["run_status"]))

    phases
    |> Enum.with_index()
    |> Enum.map(fn {phase, idx} ->
      mp = Enum.at(manifest_phases, idx)
      rp = Enum.find(result_phases, fn rp -> rp["phase_id"] == phase.phase_id end)

      name =
        cond do
          mp && is_binary(mp["name"]) && mp["name"] != "" -> format_phase_name(mp["name"])
          phase.name != phase.phase_id -> phase.name
          true -> phase.phase_id
        end

      phase_type = (mp && mp["type"]) || phase.phase_type

      # Use result duration if available (more accurate than trace timestamps)
      {started_at, ended_at} =
        if rp && is_number(rp["elapsed_ms"]) && rp["elapsed_ms"] > 0 do
          ended = phase.ended_at || phase.started_at

          started =
            with ts when is_binary(ts) <- ended,
                 {:ok, dt, _} <- DateTime.from_iso8601(ts) do
              dt |> DateTime.add(-rp["elapsed_ms"], :millisecond) |> DateTime.to_iso8601()
            else
              _ -> phase.started_at
            end

          {started, ended}
        else
          {phase.started_at, phase.ended_at}
        end

      status =
        phase_status_from_sources(
          phase.status,
          normalize_optional_status(rp && rp["status"]),
          normalize_optional_status(mp && mp["status"]),
          result_status
        )

      %{
        phase
        | name: name,
          phase_type: phase_type,
          started_at: started_at,
          ended_at: ended_at,
          status: status
      }
    end)
  end

  defp phase_status_from_sources(current, result_phase_status, manifest_phase_status, run_status) do
    cond do
      terminal_status?(result_phase_status) ->
        result_phase_status

      result_phase_status in ["running", "pending", "review"] ->
        result_phase_status

      terminal_status?(manifest_phase_status) ->
        manifest_phase_status

      terminal_status?(run_status) and current in ["running", "pending", "review"] ->
        if run_status == "failed", do: "failed", else: "done"

      true ->
        current
    end
  end

  defp normalize_optional_status(nil), do: nil
  defp normalize_optional_status(status), do: normalize_run_status(status)

  defp format_phase_name(name) do
    name
    |> String.replace(~r/[-_]/, " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # Splits events into phase groups. Uses phaseId when present, otherwise
  # infers boundaries from token_efficiency markers (which always have phaseId).
  defp group_events_by_phase(events) do
    {groups, current_phase, current_events} =
      Enum.reduce(events, {%{}, "phase-0", []}, fn e, {groups, phase, acc} ->
        cond do
          # phase_start/phase_end have explicit phaseId — start a new group
          e["eventType"] in ["phase_start", "phase_end"] and is_binary(e["phaseId"]) ->
            new_phase = e["phaseId"]
            groups = flush_phase(groups, phase, acc)
            {groups, new_phase, [e]}

          # token_efficiency marks end of a phase — flush current, advance
          e["eventType"] == "token_efficiency" and is_binary(e["phaseId"]) ->
            flush_phase_id = e["phaseId"]
            groups = flush_phase(groups, flush_phase_id, acc)
            next_phase = increment_phase(flush_phase_id)
            {groups, next_phase, []}

          # tool_call with explicit phaseId
          is_binary(e["phaseId"]) ->
            {groups, e["phaseId"], acc ++ [e]}

          # No phaseId — belongs to current inferred phase
          true ->
            {groups, phase, acc ++ [e]}
        end
      end)

    flush_phase(groups, current_phase, current_events)
  end

  defp flush_phase(groups, _phase, []), do: groups

  defp flush_phase(groups, phase, events) do
    existing = Map.get(groups, phase, [])
    Map.put(groups, phase, existing ++ events)
  end

  defp increment_phase(phase_id) do
    case Regex.run(~r/^(.+-)(\d+)$/, phase_id) do
      [_, prefix, num] -> "#{prefix}#{String.to_integer(num) + 1}"
      _ -> phase_id <> "-next"
    end
  end

  defp extract_agents(events) do
    # From phase_start metadata.agents lists
    from_phases =
      events
      |> Enum.filter(&(&1["eventType"] == "phase_start"))
      |> Enum.flat_map(fn e ->
        meta = e["metadata"] || %{}
        phase_id = e["phaseId"]
        phase_name = meta["phaseName"] || e["detail"] || phase_id

        (meta["agents"] || [])
        |> Enum.map(fn name ->
          %{name: name, phase_id: phase_id, phase_name: phase_name, source: "phase_start"}
        end)
      end)

    # Count Agent tool_call events (detail is often empty from subscription hook)
    agent_tool_calls =
      Enum.filter(events, &(&1["eventType"] == "tool_call" and &1["tool"] == "Agent"))

    from_tool_calls =
      agent_tool_calls
      |> Enum.map(fn e ->
        detail = e["detail"]
        name = if is_binary(detail) and detail != "", do: detail, else: nil
        %{name: name, phase_id: e["phaseId"], source: "tool_call"}
      end)
      |> Enum.reject(&is_nil(&1.name))

    raw_agents = if from_phases != [], do: from_phases, else: from_tool_calls
    # Deduplicate by agent name — retries create duplicate phase_start events
    agents = raw_agents |> Enum.uniq_by(& &1.name) |> Enum.reject(&is_nil(&1.name))
    %{agents: agents, agent_spawn_count: length(agent_tool_calls)}
  end

  defp maybe_filter_runs_since(runs, nil), do: runs

  defp maybe_filter_runs_since(runs, %DateTime{} = since) do
    cutoff = DateTime.to_iso8601(since)
    Enum.filter(runs, fn r -> (r.started_at || "") >= cutoff or is_nil(r.ended_at) end)
  end

  defp maybe_filter_runs_since(runs, _), do: runs

  defp parse_line(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, event} -> event
      _ -> nil
    end
  end

  # Parses a Claude Code session JSONL, extracting tool_use blocks and token usage.
  defp parse_transcript(path) do
    empty = %{tool_calls: [], tokens: %{input: 0, output: 0}}

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&parse_line/1)
      |> Stream.reject(&is_nil/1)
      |> Stream.filter(fn e -> e["type"] == "assistant" end)
      |> Enum.reduce(empty, fn entry, acc ->
        ts = entry["timestamp"]
        content = get_in(entry, ["message", "content"]) || []
        usage = get_in(entry, ["message", "usage"]) || %{}

        input_tokens =
          (usage["input_tokens"] || 0) +
            (usage["cache_creation_input_tokens"] || 0) +
            (usage["cache_read_input_tokens"] || 0)

        output_tokens = usage["output_tokens"] || 0

        tool_calls =
          content
          |> Enum.filter(fn block -> is_map(block) and block["type"] == "tool_use" end)
          |> Enum.map(fn block ->
            input = block["input"] || %{}
            file_path = input["file_path"]

            detail =
              cond do
                is_binary(file_path) ->
                  Path.basename(file_path)

                is_binary(input["command"]) ->
                  input["description"] || String.slice(input["command"], 0, 80)

                is_binary(input["pattern"]) ->
                  input["pattern"]

                is_binary(input["query"]) ->
                  input["query"]

                is_binary(input["recipient"]) ->
                  "→ #{input["recipient"]}"

                is_binary(input["taskId"]) ->
                  "##{input["taskId"]} #{input["status"] || ""}"

                true ->
                  Map.keys(input) |> Enum.take(2) |> Enum.join(", ")
              end

            tc = %{tool: block["name"], detail: detail, timestamp: ts}
            if is_binary(file_path), do: Map.put(tc, :file_path, file_path), else: tc
          end)

        %{
          tool_calls: acc.tool_calls ++ tool_calls,
          tokens: %{
            input: acc.tokens.input + input_tokens,
            output: acc.tokens.output + output_tokens
          }
        }
      end)
    else
      empty
    end
  rescue
    e in [File.Error, Jason.DecodeError] ->
      require Logger
      Logger.warning("TraceReader.parse_transcript error: #{Exception.message(e)}")
      %{tool_calls: [], tokens: %{input: 0, output: 0}}
  end

  defp claude_project_slug do
    config = Application.get_env(:crucible, :orchestrator, [])
    repo_root = Keyword.get(config, :repo_root, File.cwd!())
    String.replace(repo_root, "/", "-")
  end

  defp resolve_path(rel) do
    config = Application.get_env(:crucible, :orchestrator, [])
    repo_root = Keyword.get(config, :repo_root, File.cwd!())
    Path.join(repo_root, rel)
  end

  # Convert a cwd path to a Claude Code project slug.
  # Matches CC's algorithm: replace "/" with "-" (keeps leading "-").
  defp cwd_to_project_slug(cwd) do
    cwd
    |> String.trim_trailing("/")
    |> String.replace("/", "-")
  end

  # ---------------------------------------------------------------------------
  # MCP tool events
  # ---------------------------------------------------------------------------

  @doc "Reads MCP tool call events from the dedicated trace file."
  @spec mcp_tool_events(keyword()) :: [map()]
  def mcp_tool_events(opts \\ []) do
    path = resolve_path(Path.join(@traces_rel, "mcp-tools.jsonl"))
    limit = Keyword.get(opts, :limit, 200)

    if File.exists?(path) do
      # Read up to limit * 3 lines to allow for sorting, but cap materialization
      # to prevent OOM on large files. Final take(limit) after sort.
      read_cap = limit * 3

      path
      |> File.stream!([], :line)
      |> Stream.map(&parse_mcp_line/1)
      |> Stream.reject(&is_nil/1)
      |> Stream.take(read_cap)
      |> Enum.sort_by(& &1.timestamp, :desc)
      |> Enum.take(limit)
    else
      []
    end
  rescue
    e in [File.Error, Jason.DecodeError] ->
      require Logger
      Logger.warning("TraceReader.mcp_tool_events file error: #{Exception.message(e)}")
      []
  end

  @doc "Aggregates MCP tool events into per-tool reliability stats."
  @spec mcp_tool_stats(keyword()) :: [map()]
  def mcp_tool_stats(opts \\ []) do
    events = mcp_tool_events(opts)

    events
    |> Enum.group_by(& &1.tool)
    |> Enum.map(fn {tool, evts} ->
      succeeded = Enum.count(evts, &(&1.status == "success"))
      failed = Enum.count(evts, &(&1.status == "error"))
      denied = Enum.count(evts, &(&1.status == "denied"))

      durations =
        evts
        |> Enum.filter(&(&1.status == "success"))
        |> Enum.map(& &1.duration_ms)

      avg_dur = if durations != [], do: Enum.sum(durations) / length(durations), else: nil

      %{
        tool: tool,
        calls: length(evts),
        succeeded: succeeded,
        failed: failed,
        denied: denied,
        avg_duration_ms: avg_dur && Float.round(avg_dur, 1),
        last_seen: evts |> Enum.map(& &1.timestamp) |> Enum.max(fn -> nil end)
      }
    end)
    |> Enum.sort_by(& &1.calls, :desc)
  end

  defp parse_mcp_line(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{"eventType" => "mcp_tool_call", "tool" => tool, "timestamp" => ts} = event} ->
        metadata = event["metadata"] || %{}

        %{
          tool: tool,
          timestamp: ts,
          status: metadata["status"] || "unknown",
          duration_ms: metadata["durationMs"] || 0,
          error: event["detail"],
          agent: event["agentId"],
          session_id: event["sessionId"]
        }

      _ ->
        nil
    end
  end
end
