defmodule Crucible.SessionDiscovery do
  @moduledoc """
  Discovers active Claude Code sessions via OS process scan and JSONL lifecycle files.
  Replaces the TS dashboard's process-discovery.ts.
  """

  require Logger

  @process_cache_ttl_s 10

  @doc """
  Discovers active Claude Code sessions.
  Primary source: ~/.claude/sessions/*.json (written by Claude Code on startup).
  Fallback: ps scan for --resume flags (legacy).
  Results cached for 10 seconds via :persistent_term.
  """
  @spec active_processes() :: [map()]
  def active_processes do
    if scan_enabled?() do
      case :persistent_term.get({__MODULE__, :cache}, nil) do
        {processes, ts} when is_list(processes) ->
          if System.monotonic_time(:second) - ts < @process_cache_ttl_s do
            processes
          else
            do_scan()
          end

        _ ->
          do_scan()
      end
    else
      # Default for OSS / multi-user installs: do not scan local Claude Code
      # CLI state. Set CRUCIBLE_SCAN_LOCAL_SESSIONS=1 to opt in.
      []
    end
  end

  @doc """
  Reads session-events.jsonl to find sessions with session_end events.
  Returns a MapSet of ended session IDs.
  """
  @spec ended_sessions(String.t()) :: MapSet.t()
  def ended_sessions(log_dir) do
    path = Path.join(log_dir, "session-events.jsonl")

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.reduce(MapSet.new(), fn line, acc ->
        case Jason.decode(String.trim(line)) do
          {:ok, %{"event" => "session_end", "session" => sid}} when is_binary(sid) ->
            MapSet.put(acc, sid)

          _ ->
            acc
        end
      end)
    else
      MapSet.new()
    end
  rescue
    _ -> MapSet.new()
  end

  @doc """
  Builds unified session list by combining CostEventReader data,
  process scan, and lifecycle events. Returns string-keyed maps
  compatible with the AgentActivity component.
  """
  @spec build_sessions(String.t(), keyword()) :: [map()]
  def build_sessions(log_dir, opts \\ []) do
    run_prefix = Keyword.get(opts, :run_prefix)

    # Get cost-event sessions from reader
    cost_sessions =
      if run_prefix do
        Crucible.CostEventReader.sessions_for_run(run_prefix)
      else
        Crucible.CostEventReader.all_sessions()
      end

    # Get process and lifecycle data
    live_pids = active_processes() |> Map.new(&{&1.session_id, &1})
    ended = ended_sessions(log_dir)

    # Merge into unified ActiveSession maps
    cost_sessions
    |> Enum.map(fn sess ->
      is_alive = Map.has_key?(live_pids, sess.session_id)
      is_ended = MapSet.member?(ended, sess.session_id) and not is_alive

      %{
        "sessionId" => sess.session_id,
        "shortId" => sess.short_id,
        "project" => get_in(live_pids, [sess.session_id, :project]) || "infra",
        "cwd" => get_in(live_pids, [sess.session_id, :cwd]) || "",
        "firstSeen" => sess.first_seen,
        "lastSeen" => sess.last_seen,
        "toolCount" => sess.tool_count,
        "lastTool" => sess.last_tool,
        "lastDetail" => sess.last_detail,
        "isEnded" => is_ended,
        "runId" => sess.run_id,
        "displayName" => nil
      }
    end)
    |> Enum.sort_by(& &1["lastSeen"], :desc)
  end

  # SessionDiscovery can surface local Claude Code CLI sessions on the Activity
  # page — useful if you also run Claude Code in the same workspaces as
  # Crucible, but a privacy leak in multi-user / OSS deployments. Scanning is
  # gated behind the CRUCIBLE_SCAN_LOCAL_SESSIONS=1 env var and is OFF by
  # default. All Crucible runs should use the bridge + DB trace stream.
  @token_cache_ttl_s 30

  defp sessions_dir,
    do: System.get_env("CRUCIBLE_CLAUDE_CLI_HOME", Path.expand("~/.claude")) |> Path.join("sessions")

  defp projects_dir,
    do: System.get_env("CRUCIBLE_CLAUDE_CLI_HOME", Path.expand("~/.claude")) |> Path.join("projects")

  defp scan_enabled?, do: System.get_env("CRUCIBLE_SCAN_LOCAL_SESSIONS") == "1"

  @doc """
  Reads recent tool-use events from a session transcript for display
  in the activity feed. Returns a list of maps matching CostEventReader format.
  """
  @spec read_transcript_events(String.t(), non_neg_integer()) :: [map()]
  def read_transcript_events(session_id, limit \\ 100) do
    transcript = find_transcript_path(session_id)
    if is_nil(transcript), do: throw(:not_found)

    transcript
    |> File.stream!()
    |> Enum.reduce([], fn line, acc ->
      case Jason.decode(String.trim(line)) do
        {:ok, %{"type" => "assistant", "message" => %{"content" => content}} = data}
            when is_list(content) ->
          ts = data["timestamp"] || ""

          tools =
            content
            |> Enum.filter(&match?(%{"type" => "tool_use"}, &1))
            |> Enum.map(fn tool ->
              %{
                "tool" => tool["name"],
                "timestamp" => ts,
                "detail" => truncate_detail(tool["input"])
              }
            end)

          acc ++ tools

        _ ->
          acc
      end
    end)
    |> Enum.take(-limit)
    |> Enum.reverse()
  rescue
    _ -> []
  catch
    _ -> []
  end

  defp find_transcript_path(session_id) do
    if File.dir?(projects_dir()) do
      projects_dir()
      |> File.ls!()
      |> Enum.find_value(fn dir ->
        # Direct session transcript
        path = Path.join([projects_dir(), dir, "#{session_id}.jsonl"])

        if File.exists?(path) do
          path
        else
          # Search subagent transcripts: {projectDir}/{parentSession}/subagents/agent-{id}.jsonl
          # Subagent IDs start with "agent-a" prefix
          find_subagent_transcript(Path.join(projects_dir(), dir), session_id)
        end
      end)
    end
  rescue
    _ -> nil
  end

  # Search for a subagent transcript by scanning subagents/ dirs under each parent session.
  defp find_subagent_transcript(project_dir, session_id) do
    if File.dir?(project_dir) do
      project_dir
      |> File.ls!()
      |> Enum.find_value(fn entry ->
        subagents_dir = Path.join([project_dir, entry, "subagents"])

        if File.dir?(subagents_dir) do
          path = Path.join(subagents_dir, "#{session_id}.jsonl")
          if File.exists?(path), do: path
        end
      end)
    end
  rescue
    _ -> nil
  end

  defp truncate_detail(nil), do: nil
  defp truncate_detail(input) when is_map(input) do
    # Extract the most useful field from tool input for display
    cond do
      Map.has_key?(input, "command") -> String.slice(to_string(input["command"]), 0, 80)
      Map.has_key?(input, "file_path") -> input["file_path"]
      Map.has_key?(input, "pattern") -> "#{input["pattern"]}"
      Map.has_key?(input, "query") -> String.slice(to_string(input["query"]), 0, 80)
      Map.has_key?(input, "prompt") -> String.slice(to_string(input["prompt"]), 0, 60)
      Map.has_key?(input, "description") -> String.slice(to_string(input["description"]), 0, 80)
      true -> nil
    end
  end
  defp truncate_detail(_), do: nil

  @doc """
  Reads token usage from a session's transcript JSONL.
  Transcript lives at ~/.claude/projects/{encoded-cwd}/{sessionId}.jsonl.
  Results cached for 30 seconds per session.
  Returns %{input: int, output: int, cache_read: int, cache_create: int, tool_count: int, last_tool: binary | nil}.
  """
  @spec read_transcript_tokens(String.t()) :: map()
  def read_transcript_tokens(session_id) do
    cache_key = {__MODULE__, :tokens, session_id}

    case :persistent_term.get(cache_key, nil) do
      {tokens, ts} when is_map(tokens) ->
        if System.monotonic_time(:second) - ts < @token_cache_ttl_s do
          tokens
        else
          do_read_tokens(session_id, cache_key)
        end

      _ ->
        do_read_tokens(session_id, cache_key)
    end
  end

  defp do_read_tokens(session_id, cache_key) do
    tokens = find_and_sum_transcript(session_id)
    :persistent_term.put(cache_key, {tokens, System.monotonic_time(:second)})
    tokens
  end

  defp find_and_sum_transcript(session_id) do
    empty = %{input: 0, output: 0, cache_read: 0, cache_create: 0, tool_count: 0, last_tool: nil}

    transcript = find_transcript_path(session_id)
    if is_nil(transcript), do: throw(:not_found)

    transcript
    |> File.stream!()
    |> Enum.reduce(empty, fn line, acc ->
      case Jason.decode(String.trim(line)) do
        {:ok, data} ->
          acc = count_tool_use(acc, data)
          usage = extract_usage(data)

          if usage do
            %{
              acc
              | input: acc.input + (usage["input_tokens"] || 0),
                output: acc.output + (usage["output_tokens"] || 0),
                cache_read: acc.cache_read + (usage["cache_read_input_tokens"] || 0),
                cache_create: acc.cache_create + (usage["cache_creation_input_tokens"] || 0)
            }
          else
            acc
          end

        _ ->
          acc
      end
    end)
  rescue
    _ -> %{input: 0, output: 0, cache_read: 0, cache_create: 0, tool_count: 0, last_tool: nil}
  catch
    _ -> %{input: 0, output: 0, cache_read: 0, cache_create: 0, tool_count: 0, last_tool: nil}
  end

  # Count tool_use blocks from assistant messages in the transcript
  defp count_tool_use(acc, %{"type" => "assistant", "message" => %{"content" => content}})
       when is_list(content) do
    tools =
      Enum.filter(content, fn
        %{"type" => "tool_use"} -> true
        _ -> false
      end)

    case tools do
      [] ->
        acc

      _ ->
        last = List.last(tools)

        %{
          acc
          | tool_count: acc.tool_count + length(tools),
            last_tool: last["name"] || acc.last_tool
        }
    end
  end

  defp count_tool_use(acc, _data), do: acc

  defp extract_usage(data) do
    # Transcript entries have either data.message.usage or message.usage
    msg =
      get_in(data, ["message"]) ||
        get_in(data, ["data", "message"]) ||
        %{}

    msg["usage"]
  end

  # ---------------------------------------------------------------------------
  # Session discovery
  # ---------------------------------------------------------------------------

  defp do_scan do
    processes = scan_session_files() ++ scan_ps_fallback()

    # For each process, check if there's a newer transcript in the same project dir.
    # Claude Code can start a new session (new UUID) in the same terminal without
    # updating the session JSON file.
    processes =
      Enum.map(processes, fn proc ->
        case find_newest_transcript_for_cwd(proc.cwd) do
          {newest_id, _path} when newest_id != proc.session_id ->
            Logger.debug("SessionDiscovery: #{proc.session_id} replaced by #{newest_id} in #{proc.cwd}")
            %{proc | session_id: newest_id}

          _ ->
            proc
        end
      end)
      |> Enum.uniq_by(& &1.session_id)

    :persistent_term.put({__MODULE__, :cache}, {processes, System.monotonic_time(:second)})
    processes
  end

  # Find the most recently modified transcript JSONL in the project dir for a given cwd
  defp find_newest_transcript_for_cwd(nil), do: nil
  defp find_newest_transcript_for_cwd(""), do: nil

  defp find_newest_transcript_for_cwd(cwd) do
    # Encode cwd the same way Claude does: replace / with -
    encoded = String.replace(cwd, "/", "-")
    dir = Path.join(projects_dir(), encoded)

    if File.dir?(dir) do
      case File.ls(dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
          |> Enum.map(fn file ->
            path = Path.join(dir, file)
            session_id = String.replace_trailing(file, ".jsonl", "")
            mtime = case File.stat(path) do
              {:ok, %{mtime: mtime}} -> mtime
              _ -> {{2000, 1, 1}, {0, 0, 0}}
            end
            {session_id, path, mtime}
          end)
          |> Enum.max_by(fn {_id, _path, mtime} -> mtime end, fn -> nil end)
          |> case do
            nil -> nil
            {id, path, _mtime} -> {id, path}
          end

        {:error, reason} ->
          Logger.warning("SessionDiscovery: failed to list #{dir}: #{inspect(reason)}")
          nil
      end
    else
      nil
    end
  end

  # Primary: read ~/.claude/sessions/*.json — each file is a live session
  # File format: {"pid": 12345, "sessionId": "uuid", "cwd": "/path", "startedAt": epoch_ms}
  defp scan_session_files do
    if File.dir?(sessions_dir()) do
      candidates =
        Path.wildcard(Path.join(sessions_dir(), "*.json"))
        |> Enum.map(&parse_session_file/1)
        |> Enum.reject(&is_nil/1)

      # Batch process-alive check: one `ps` call instead of N `kill -0` subprocesses
      alive_pids = batch_alive_pids(Enum.map(candidates, & &1.pid))
      Enum.filter(candidates, &MapSet.member?(alive_pids, &1.pid))
    else
      []
    end
  rescue
    _ -> []
  end

  # Single `ps` call to check which PIDs are alive — O(1) subprocess instead of O(n)
  defp batch_alive_pids(pids) when pids == [], do: MapSet.new()

  defp batch_alive_pids(pids) do
    pid_strs = Enum.map(pids, &to_string/1) |> Enum.join(",")

    case System.cmd("ps", ["-p", pid_strs, "-o", "pid="], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.to_integer/1)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  rescue
    _ -> MapSet.new()
  end

  defp parse_session_file(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, data} <- Jason.decode(raw),
         pid when is_integer(pid) <- data["pid"],
         session_id when is_binary(session_id) <- data["sessionId"] do
      %{
        pid: pid,
        session_id: session_id,
        cwd: data["cwd"] || "",
        project: Path.basename(data["cwd"] || "unknown"),
        started_at: data["startedAt"]
      }
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Fallback: ps scan for older Claude versions that use --resume
  defp scan_ps_fallback do
    try do
      {output, 0} =
        System.cmd("bash", [
          "-c",
          ~s(ps ax -o pid=,args= 2>/dev/null | grep -E "[c]laude.*--resume" | head -30)
        ])

      output
      |> String.split("\n", trim: true)
      |> Enum.map(&parse_ps_line/1)
      |> Enum.reject(&is_nil/1)
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  defp parse_ps_line(line) do
    line = String.trim(line)

    with [pid_str | _rest] <- String.split(line, ~r/\s+/, parts: 2),
         {pid, ""} <- Integer.parse(pid_str),
         {:ok, session_id} <- extract_resume_id(line) do
      %{
        pid: pid,
        session_id: session_id,
        cwd: "",
        project: "unknown"
      }
    else
      _ -> nil
    end
  end

  defp extract_resume_id(line) do
    case Regex.run(~r/--resume\s+([0-9a-f-]{36})/, line) do
      [_, uuid] -> {:ok, uuid}
      _ -> :error
    end
  end
end
