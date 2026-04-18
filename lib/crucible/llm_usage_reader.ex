defmodule Crucible.LLMUsageReader do
  @moduledoc """
  Builds the same transcript-derived LLM usage summary used by the TypeScript dashboard.

  Source of truth:
  - Claude session transcripts under `~/.claude/projects/**`
  - Run snapshot + lifecycle files under `.claude-flow/` for run-scoped filtering
  """

  @cache_table :crucible_llm_usage_cache
  @cache_ttl_ms 30_000
  @default_min_file_size 1_024
  @default_max_file_size 10 * 1024 * 1024

  @spec build_summary(keyword()) :: map()
  def build_summary(opts \\ []) do
    opts = resolve_opts(opts)

    cache_key =
      {
        opts[:projects_root],
        opts[:infra_home],
        opts[:run_id],
        opts[:include_subscription],
        opts[:session_limit]
      }

    if opts[:cache] do
      ensure_cache_table()

      case lookup_cache(cache_key) do
        {:ok, data} ->
          data

        :miss ->
          data = do_build_summary(opts)
          put_cache(cache_key, data)
          data
      end
    else
      do_build_summary(opts)
    end
  end

  @spec cache_entries() :: non_neg_integer()
  def cache_entries do
    case :ets.whereis(@cache_table) do
      :undefined -> 0
      tid -> :ets.info(tid, :size) || 0
    end
  rescue
    _ -> 0
  end

  defp resolve_opts(opts) do
    config = Application.get_env(:crucible, :llm_usage_reader, [])

    infra_home =
      Keyword.get_lazy(opts, :infra_home, fn ->
        Keyword.get(config, :infra_home, repo_root())
      end)

    projects_root =
      Keyword.get_lazy(opts, :projects_root, fn ->
        Keyword.get(config, :projects_root, Path.join(System.user_home!(), ".claude/projects"))
      end)

    [
      infra_home: infra_home,
      projects_root: projects_root,
      run_id: Keyword.get(opts, :run_id),
      extra_session_ids: normalize_extra_session_ids(Keyword.get(opts, :extra_session_ids)),
      include_subscription:
        Keyword.get(opts, :include_subscription, Keyword.get(config, :include_subscription, true)),
      session_limit: Keyword.get(opts, :session_limit, Keyword.get(config, :session_limit, 30)),
      cache: Keyword.get(opts, :cache, Keyword.get(config, :cache, true)),
      min_file_size:
        Keyword.get(
          opts,
          :min_file_size,
          Keyword.get(config, :min_file_size, @default_min_file_size)
        ),
      max_file_size:
        Keyword.get(
          opts,
          :max_file_size,
          Keyword.get(config, :max_file_size, @default_max_file_size)
        )
    ]
  end

  defp do_build_summary(opts) do
    run_session_ids =
      case opts[:run_id] do
        nil -> nil
        run_id -> collect_run_session_ids(opts[:infra_home], run_id)
      end

    run_session_ids =
      merge_extra_session_ids(run_session_ids, opts[:extra_session_ids])

    if opts[:run_id] && (is_nil(run_session_ids) || MapSet.size(run_session_ids) == 0) do
      empty_summary(opts[:include_subscription])
    else
      sessions =
        opts[:projects_root]
        |> discover_project_dirs()
        |> Enum.flat_map(fn %{dir_path: dir_path, project: project} ->
          collect_project_sessions(dir_path, project, run_session_ids, opts)
        end)
        |> maybe_filter_subscription(opts[:include_subscription])
        |> Enum.sort_by(&Map.get(&1, "lastSeen", ""), :desc)

      by_model = aggregate_by_model(sessions)
      by_project = aggregate_by_project(sessions)
      by_date = aggregate_by_date(sessions)
      by_date_model = aggregate_by_date_model(sessions)

      %{
        "totalInputTokens" => Enum.reduce(sessions, 0, &(&2 + (&1["inputTokens"] || 0))),
        "totalOutputTokens" => Enum.reduce(sessions, 0, &(&2 + (&1["outputTokens"] || 0))),
        "totalCacheCreation" =>
          Enum.reduce(sessions, 0, &(&2 + (&1["cacheCreationTokens"] || 0))),
        "totalCacheRead" => Enum.reduce(sessions, 0, &(&2 + (&1["cacheReadTokens"] || 0))),
        "totalTokens" => Enum.reduce(sessions, 0, &(&2 + (&1["totalTokens"] || 0))),
        "totalTurns" => Enum.reduce(sessions, 0, &(&2 + (&1["turns"] || 0))),
        "sessionCount" => length(sessions),
        "includesSubscription" => opts[:include_subscription],
        "sessions" => Enum.take(sessions, max(opts[:session_limit] || 30, 0)),
        "byModel" => by_model,
        "byProject" => by_project,
        "byDate" => by_date,
        "byDateModel" => by_date_model
      }
    end
  end

  defp collect_project_sessions(dir_path, project, run_session_ids, opts) do
    [dir_path, Path.join(dir_path, "subagents")]
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(fn scan_dir ->
      case File.ls(scan_dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
          |> Enum.flat_map(fn file ->
            session_id = String.trim_trailing(file, ".jsonl")

            cond do
              run_session_ids && not MapSet.member?(run_session_ids, session_id) ->
                []

              true ->
                path = Path.join(scan_dir, file)

                if valid_transcript_size?(path, opts[:min_file_size], opts[:max_file_size]) do
                  case parse_transcript_usage(path, session_id, project) do
                    nil -> []
                    usage -> [usage]
                  end
                else
                  []
                end
            end
          end)

        {:error, _} ->
          []
      end
    end)
  end

  defp valid_transcript_size?(path, min_file_size, max_file_size) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size >= min_file_size and size <= max_file_size
      _ -> false
    end
  end

  defp parse_transcript_usage(path, session_id, project) do
    path
    |> File.stream!()
    |> Enum.reduce(
      %{
        "sessionId" => session_id,
        "project" => project,
        "model" => "unknown",
        "inputTokens" => 0,
        "outputTokens" => 0,
        "cacheCreationTokens" => 0,
        "cacheReadTokens" => 0,
        "totalTokens" => 0,
        "turns" => 0,
        "firstSeen" => "",
        "lastSeen" => "",
        "executionType" => "subscription"
      },
      fn line, acc ->
        case Jason.decode(line) do
          {:ok, %{"message" => %{"usage" => usage} = message} = entry} when is_map(usage) ->
            input_tokens = usage["input_tokens"] || 0
            output_tokens = usage["output_tokens"] || 0
            cache_creation = usage["cache_creation_input_tokens"] || 0
            cache_read = usage["cache_read_input_tokens"] || 0
            timestamp = entry["timestamp"] || ""
            model = message["model"] || acc["model"]

            %{
              acc
              | "model" => model,
                "inputTokens" => acc["inputTokens"] + input_tokens,
                "outputTokens" => acc["outputTokens"] + output_tokens,
                "cacheCreationTokens" => acc["cacheCreationTokens"] + cache_creation,
                "cacheReadTokens" => acc["cacheReadTokens"] + cache_read,
                "totalTokens" =>
                  acc["totalTokens"] + input_tokens + output_tokens + cache_creation,
                "turns" => acc["turns"] + 1,
                "firstSeen" => min_timestamp(acc["firstSeen"], timestamp),
                "lastSeen" => max_timestamp(acc["lastSeen"], timestamp)
            }

          _ ->
            acc
        end
      end
    )
    |> case do
      %{"turns" => 0} -> nil
      usage -> usage
    end
  rescue
    _ -> nil
  end

  defp aggregate_by_model(sessions) do
    Enum.reduce(sessions, %{}, fn session, acc ->
      model = session["model"] || "unknown"

      Map.update(
        acc,
        model,
        %{
          "inputTokens" => session["inputTokens"] || 0,
          "outputTokens" => session["outputTokens"] || 0,
          "cacheCreation" => session["cacheCreationTokens"] || 0,
          "cacheRead" => session["cacheReadTokens"] || 0,
          "totalTokens" => session["totalTokens"] || 0,
          "turns" => session["turns"] || 0
        },
        fn existing ->
          %{
            "inputTokens" => existing["inputTokens"] + (session["inputTokens"] || 0),
            "outputTokens" => existing["outputTokens"] + (session["outputTokens"] || 0),
            "cacheCreation" => existing["cacheCreation"] + (session["cacheCreationTokens"] || 0),
            "cacheRead" => existing["cacheRead"] + (session["cacheReadTokens"] || 0),
            "totalTokens" => existing["totalTokens"] + (session["totalTokens"] || 0),
            "turns" => existing["turns"] + (session["turns"] || 0)
          }
        end
      )
    end)
  end

  defp aggregate_by_project(sessions) do
    Enum.reduce(sessions, %{}, fn session, acc ->
      project = session["project"] || "unknown"

      Map.update(
        acc,
        project,
        %{
          "inputTokens" => session["inputTokens"] || 0,
          "outputTokens" => session["outputTokens"] || 0,
          "cacheCreation" => session["cacheCreationTokens"] || 0,
          "cacheRead" => session["cacheReadTokens"] || 0,
          "totalTokens" => session["totalTokens"] || 0,
          "turns" => session["turns"] || 0,
          "sessions" => 1
        },
        fn existing ->
          %{
            "inputTokens" => existing["inputTokens"] + (session["inputTokens"] || 0),
            "outputTokens" => existing["outputTokens"] + (session["outputTokens"] || 0),
            "cacheCreation" => existing["cacheCreation"] + (session["cacheCreationTokens"] || 0),
            "cacheRead" => existing["cacheRead"] + (session["cacheReadTokens"] || 0),
            "totalTokens" => existing["totalTokens"] + (session["totalTokens"] || 0),
            "turns" => existing["turns"] + (session["turns"] || 0),
            "sessions" => existing["sessions"] + 1
          }
        end
      )
    end)
  end

  defp aggregate_by_date(sessions) do
    Enum.reduce(sessions, %{}, fn session, acc ->
      case String.slice(session["lastSeen"] || "", 0, 10) do
        "" ->
          acc

        date ->
          Map.update(
            acc,
            date,
            session["totalTokens"] || 0,
            &(&1 + (session["totalTokens"] || 0))
          )
      end
    end)
  end

  defp aggregate_by_date_model(sessions) do
    Enum.reduce(sessions, %{}, fn session, acc ->
      date = String.slice(session["lastSeen"] || "", 0, 10)
      model = session["model"] || "unknown"

      if date == "" do
        acc
      else
        Map.update(
          acc,
          date,
          %{model => session["totalTokens"] || 0},
          fn existing ->
            Map.update(
              existing,
              model,
              session["totalTokens"] || 0,
              &(&1 + (session["totalTokens"] || 0))
            )
          end
        )
      end
    end)
  end

  defp discover_project_dirs(projects_root) do
    case File.ls(projects_root) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn entry ->
          dir_path = Path.join(projects_root, entry)

          if File.dir?(dir_path) do
            [
              %{
                dir_path: dir_path,
                project: project_name(entry)
              }
            ]
          else
            []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp project_name(entry) do
    entry
    |> String.split("-")
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> case do
      nil -> entry
      project -> project
    end
  end

  defp collect_run_session_ids(infra_home, run_id) do
    runs_dir = Path.join([infra_home, ".claude-flow", "runs"])
    prefix = String.slice(run_id, 0, 8)

    {ids, team_names} =
      case File.ls(runs_dir) do
        {:ok, files} ->
          Enum.reduce(files, {MapSet.new(), MapSet.new()}, fn file, {ids_acc, teams_acc} ->
            if String.ends_with?(file, "-snapshot.json") and String.contains?(file, prefix) do
              parse_snapshot(Path.join(runs_dir, file), ids_acc, teams_acc)
            else
              {ids_acc, teams_acc}
            end
          end)

        {:error, _} ->
          {MapSet.new(), MapSet.new()}
      end

    lifecycle_ids = collect_lifecycle_session_ids(infra_home, team_names)
    combined = Enum.reduce(lifecycle_ids, ids, &MapSet.put(&2, &1))
    if MapSet.size(combined) > 0, do: combined, else: nil
  end

  defp parse_snapshot(path, ids_acc, teams_acc) do
    with {:ok, content} <- File.read(path),
         {:ok, snapshot} <- Jason.decode(content) do
      ids_acc =
        ids_acc
        |> maybe_put(snapshot["leadSessionId"])
        |> add_member_ids(snapshot["members"] || [])

      teams_acc = maybe_put(teams_acc, snapshot["teamName"])
      {ids_acc, teams_acc}
    else
      _ -> {ids_acc, teams_acc}
    end
  end

  defp add_member_ids(ids_acc, members) when is_list(members) do
    Enum.reduce(members, ids_acc, fn member, acc ->
      acc
      |> maybe_put(member["sessionId"])
      |> maybe_put(member["memberSessionId"])
    end)
  end

  defp add_member_ids(ids_acc, _), do: ids_acc

  defp collect_lifecycle_session_ids(infra_home, team_names) do
    lifecycle_path = Path.join([infra_home, ".claude-flow", "logs", "agent-lifecycle.jsonl"])

    if File.exists?(lifecycle_path) and MapSet.size(team_names) > 0 do
      lifecycle_path
      |> File.stream!()
      |> Enum.reduce(MapSet.new(), fn line, acc ->
        case Jason.decode(line) do
          {:ok,
           %{"event" => "teammate_idle", "team_name" => team_name, "session_id" => session_id}}
          when is_binary(team_name) and is_binary(session_id) ->
            if MapSet.member?(team_names, team_name), do: MapSet.put(acc, session_id), else: acc

          _ ->
            acc
        end
      end)
      |> MapSet.to_list()
    else
      []
    end
  rescue
    _ -> []
  end

  defp maybe_filter_subscription(sessions, true), do: sessions

  defp maybe_filter_subscription(sessions, false),
    do: Enum.filter(sessions, &(&1["executionType"] == "api"))

  defp normalize_extra_session_ids(nil), do: MapSet.new()

  defp normalize_extra_session_ids(%MapSet{} = extra_session_ids), do: extra_session_ids

  defp normalize_extra_session_ids(extra_session_ids) when is_list(extra_session_ids) do
    extra_session_ids
    |> Enum.reduce(MapSet.new(), fn
      session_id, acc when is_binary(session_id) and session_id != "" ->
        MapSet.put(acc, session_id)

      _session_id, acc ->
        acc
    end)
  end

  defp normalize_extra_session_ids(_), do: MapSet.new()

  defp merge_extra_session_ids(nil, extra_session_ids) do
    if MapSet.size(extra_session_ids) > 0, do: extra_session_ids, else: nil
  end

  defp merge_extra_session_ids(run_session_ids, extra_session_ids) do
    Enum.reduce(extra_session_ids, run_session_ids, &MapSet.put(&2, &1))
  end

  defp empty_summary(include_subscription) do
    %{
      "totalInputTokens" => 0,
      "totalOutputTokens" => 0,
      "totalCacheCreation" => 0,
      "totalCacheRead" => 0,
      "totalTokens" => 0,
      "totalTurns" => 0,
      "sessionCount" => 0,
      "includesSubscription" => include_subscription,
      "sessions" => [],
      "byModel" => %{},
      "byProject" => %{},
      "byDate" => %{},
      "byDateModel" => %{}
    }
  end

  defp min_timestamp("", timestamp), do: timestamp || ""
  defp min_timestamp(timestamp, ""), do: timestamp || ""
  defp min_timestamp(a, b) when is_binary(a) and is_binary(b), do: if(a <= b, do: a, else: b)

  defp max_timestamp("", timestamp), do: timestamp || ""
  defp max_timestamp(timestamp, ""), do: timestamp || ""
  defp max_timestamp(a, b) when is_binary(a) and is_binary(b), do: if(a >= b, do: a, else: b)

  defp maybe_put(set, value) when is_binary(value) and value != "", do: MapSet.put(set, value)
  defp maybe_put(set, _value), do: set

  defp repo_root do
    Application.get_env(:crucible, :orchestrator, [])
    |> Keyword.get(:repo_root, File.cwd!())
  end

  defp ensure_cache_table do
    case :ets.whereis(@cache_table) do
      :undefined -> :ets.new(@cache_table, [:named_table, :public, read_concurrency: true])
      _ -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp lookup_cache(key) do
    case :ets.lookup(@cache_table, key) do
      [{^key, ts, data}] ->
        if System.monotonic_time(:millisecond) - ts < @cache_ttl_ms do
          {:ok, data}
        else
          :miss
        end

      _ ->
        :miss
    end
  end

  defp put_cache(key, data) do
    :ets.insert(@cache_table, {key, System.monotonic_time(:millisecond), data})
    data
  end
end
