defmodule Crucible.CostEventReader do
  @moduledoc """
  Reads cost-events.jsonl with file-position tracking for efficient tailing.
  Maintains in-memory session aggregation so LiveViews can query without re-parsing.
  """

  use GenServer
  import Ecto.Query

  alias Crucible.Repo
  alias Crucible.RollupCache
  alias Crucible.Schema.{TraceEvent, WorkflowRun}
  alias Crucible.Telemetry.Spans
  require Logger

  @tick_interval 5_000
  @call_timeout 10_000
  @max_events_per_session 200
  @session_ttl_hours 24
  @cache_enabled_default Mix.env() != :test
  @all_sessions_cache_ttl_ms 5_000
  @stats_cache_ttl_ms 5_000
  @source_status_cache_ttl_ms 5_000

  defstruct [
    :file_path,
    file_position: 0,
    file_size: 0,
    sessions: %{},
    events_by_session: %{},
    events_by_agent: %{},
    events_by_task: %{},
    # Cumulative counters that survive session pruning
    cumulative_sessions: 0,
    cumulative_tool_calls: 0,
    cumulative_cost: 0.0
  ]

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns all sessions sorted by last_seen desc. Accepts `since: DateTime`."
  @spec all_sessions(keyword()) :: [map()]
  def all_sessions(opts \\ []) do
    Spans.with_span("cost_event_reader.all_sessions", fn ->
      with_rollup_cache(
        opts,
        {
          :cost_event_reader,
          :all_sessions,
          normalize_cache_since(Keyword.get(opts, :since)),
          normalize_cache_scope(Keyword.get(opts, :client_id)),
          normalize_cache_scope(Keyword.get(opts, :workspace)),
          normalize_cache_scope(normalize_limit(Keyword.get(opts, :limit)))
        },
        @all_sessions_cache_ttl_ms,
        fn -> do_all_sessions(opts) end
      )
    end)
  catch
    :exit, _ -> []
  end

  @doc "Returns sessions matching an 8-char run_id prefix."
  @spec sessions_for_run(String.t()) :: [map()]
  def sessions_for_run(run_prefix) do
    case db_sessions_for_run(run_prefix) do
      {:ok, [_ | _] = sessions} ->
        sessions

      {:ok, []} ->
        GenServer.call(__MODULE__, {:sessions_for_run, run_prefix}, @call_timeout)

      _ ->
        GenServer.call(__MODULE__, {:sessions_for_run, run_prefix}, @call_timeout)
    end
  catch
    :exit, _ -> []
  end

  @doc "Returns the last N events for a session."
  @spec session_events(String.t(), keyword()) :: [map()]
  def session_events(session_id, opts \\ []) do
    case db_session_events(session_id, opts) do
      {:ok, [_ | _] = events} ->
        events

      {:ok, []} ->
        GenServer.call(__MODULE__, {:session_events, session_id, opts}, @call_timeout)

      _ ->
        GenServer.call(__MODULE__, {:session_events, session_id, opts}, @call_timeout)
    end
  catch
    :exit, _ -> []
  end

  @doc "Returns the last N events for a specific agent_id."
  @spec agent_events(String.t(), keyword()) :: [map()]
  def agent_events(agent_id, opts \\ []) do
    case db_agent_events(agent_id, opts) do
      {:ok, [_ | _] = events} ->
        events

      {:ok, []} ->
        GenServer.call(__MODULE__, {:agent_events, agent_id, opts}, @call_timeout)

      _ ->
        GenServer.call(__MODULE__, {:agent_events, agent_id, opts}, @call_timeout)
    end
  catch
    :exit, _ -> []
  end

  @doc "Returns summary stats: total sessions, tool calls, cost."
  @spec stats(keyword()) :: map()
  def stats(opts \\ []) do
    Spans.with_span("cost_event_reader.stats", fn ->
      with_rollup_cache(
        opts,
        {
          :cost_event_reader,
          :stats,
          normalize_cache_since(Keyword.get(opts, :since)),
          normalize_cache_scope(Keyword.get(opts, :client_id)),
          normalize_cache_scope(Keyword.get(opts, :workspace)),
          normalize_cache_scope(normalize_limit(Keyword.get(opts, :limit)))
        },
        @stats_cache_ttl_ms,
        fn -> do_stats(opts) end
      )
    end)
  catch
    :exit, _ -> %{total_sessions: 0, total_tool_calls: 0, total_cost: 0.0}
  end

  @doc "Reports the currently effective source for session rollups."
  @spec source_status(keyword()) :: %{source: atom(), confidence: String.t()}
  def source_status(opts \\ []) do
    with_rollup_cache(
      opts,
      {
        :cost_event_reader,
        :source_status,
        normalize_cache_since(Keyword.get(opts, :since)),
        normalize_cache_scope(Keyword.get(opts, :client_id)),
        normalize_cache_scope(Keyword.get(opts, :workspace)),
        normalize_cache_scope(normalize_limit(Keyword.get(opts, :limit)))
      },
      @source_status_cache_ttl_ms,
      fn -> do_source_status(opts) end
    )
  rescue
    _ -> %{source: :unknown, confidence: "low"}
  end

  @doc "Returns sessions aggregated with spend, events, last activity. Matches TS /api/budget/sessions shape."
  @spec session_rollups(keyword()) :: [map()]
  def session_rollups(opts \\ []) do
    with_rollup_cache(
      opts,
      {
        :cost_event_reader,
        :session_rollups,
        normalize_cache_since(Keyword.get(opts, :since)),
        normalize_cache_scope(Keyword.get(opts, :client_id)),
        normalize_cache_scope(Keyword.get(opts, :workspace))
      },
      @all_sessions_cache_ttl_ms,
      fn ->
        all_sessions(opts)
        |> Enum.map(fn s ->
          %{
            "session" => Map.get(s, :short_id, "—"),
            "spent" => Map.get(s, :total_cost_usd, 0.0),
            "events" => Map.get(s, :tool_count, 0),
            "lastActivity" => Map.get(s, :last_seen)
          }
        end)
      end
    )
  catch
    :exit, _ -> []
  end

  @doc "Returns per-agent aggregates. Matches TS /api/budget/agents shape."
  @spec agent_rollups(keyword()) :: [map()]
  def agent_rollups(opts \\ []) do
    with_rollup_cache(
      opts,
      {
        :cost_event_reader,
        :agent_rollups,
        normalize_cache_since(Keyword.get(opts, :since)),
        normalize_cache_scope(Keyword.get(opts, :client_id)),
        normalize_cache_scope(Keyword.get(opts, :workspace))
      },
      @all_sessions_cache_ttl_ms,
      fn -> do_agent_rollups(opts) end
    )
  catch
    :exit, _ -> []
  end

  @doc "Returns per-task aggregates. Matches TS /api/budget/tasks shape."
  @spec task_rollups(keyword()) :: [map()]
  def task_rollups(opts \\ []) do
    with_rollup_cache(
      opts,
      {
        :cost_event_reader,
        :task_rollups,
        normalize_cache_since(Keyword.get(opts, :since)),
        normalize_cache_scope(Keyword.get(opts, :client_id)),
        normalize_cache_scope(Keyword.get(opts, :workspace))
      },
      @all_sessions_cache_ttl_ms,
      fn -> GenServer.call(__MODULE__, {:task_rollups, opts}, @call_timeout) end
    )
  catch
    :exit, _ -> []
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    file_path = Keyword.fetch!(opts, :file_path)
    state = %__MODULE__{file_path: file_path}

    state = full_read(state)
    schedule_tick()
    {:ok, state}
  end

  @impl true
  def handle_call({:all_sessions, opts}, _from, state) do
    since = Keyword.get(opts, :since)
    workspace = Keyword.get(opts, :workspace)
    limit = normalize_limit(Keyword.get(opts, :limit))

    sessions =
      state.sessions
      |> Map.values()
      |> maybe_filter_since(since)
      |> maybe_filter_workspace(workspace)
      |> Enum.sort_by(& &1.last_seen, :desc)
      |> maybe_take_limit(limit)

    {:reply, sessions, state}
  end

  def handle_call({:sessions_for_run, run_prefix}, _from, state) do
    sessions =
      state.sessions
      |> Map.values()
      |> Enum.filter(&((&1.run_id || "") |> String.starts_with?(run_prefix)))
      |> Enum.sort_by(& &1.last_seen, :desc)

    {:reply, sessions, state}
  end

  def handle_call({:session_events, session_id, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, @max_events_per_session)

    events =
      state.events_by_session
      |> Map.get(session_id, [])
      |> Enum.take(-limit)
      |> Enum.reverse()

    {:reply, events, state}
  end

  def handle_call({:agent_events, agent_id, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, @max_events_per_session)

    events =
      state.events_by_agent
      |> Map.get(agent_id, [])
      |> Enum.take(-limit)

    {:reply, events, state}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      total_sessions: state.cumulative_sessions,
      total_tool_calls: state.cumulative_tool_calls,
      total_cost: state.cumulative_cost
    }

    {:reply, stats, state}
  end

  def handle_call({:agent_rollups, opts}, _from, state) do
    since = Keyword.get(opts, :since)

    rollups =
      state.events_by_agent
      |> Enum.map(fn {agent_id, events} ->
        events = maybe_filter_events_since(events, since)
        aggregate_agent_events(agent_id, events)
      end)
      |> Enum.reject(&(&1["events"] == 0))

    # Also include events with no agent_id, grouped by session_id
    session_only =
      state.events_by_session
      |> Enum.flat_map(fn {_sid, events} ->
        Enum.filter(events, &(is_nil(&1.agent_id) or &1.agent_id == ""))
      end)
      |> maybe_filter_events_since(since)
      |> Enum.group_by(fn e -> e.session_id end)
      |> Enum.map(fn {sid, events} ->
        aggregate_agent_events(sid, events)
      end)
      |> Enum.reject(&(&1["events"] == 0))

    result =
      (rollups ++ session_only)
      |> Enum.sort_by(& &1["events"], :desc)

    {:reply, result, state}
  end

  def handle_call({:task_rollups, opts}, _from, state) do
    since = Keyword.get(opts, :since)

    rollups =
      state.events_by_task
      |> Enum.map(fn {task_id, events} ->
        events = maybe_filter_events_since(events, since)
        aggregate_task_events(task_id, events)
      end)
      |> Enum.reject(&(&1["events"] == 0))
      |> Enum.sort_by(& &1["events"], :desc)

    {:reply, rollups, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = incremental_read(state)
    state = prune_old_sessions(state)
    schedule_tick()
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # DB-first query path (single source of truth when trace_events is populated)
  # ---------------------------------------------------------------------------

  defp do_all_sessions(opts) do
    case db_all_sessions(opts) do
      {:ok, [_ | _] = sessions} ->
        sessions

      {:ok, []} ->
        GenServer.call(__MODULE__, {:all_sessions, opts}, @call_timeout)

      _ ->
        GenServer.call(__MODULE__, {:all_sessions, opts}, @call_timeout)
    end
  end

  defp do_stats(opts) do
    case db_stats(opts) do
      {:ok, stats} -> stats
      _ -> stats_from_sessions(do_all_sessions(opts))
    end
  end

  defp do_source_status(opts) do
    case db_all_sessions(opts) do
      {:ok, [_ | _]} ->
        %{source: :postgres, confidence: "high"}

      {:ok, []} ->
        local =
          try do
            GenServer.call(__MODULE__, {:all_sessions, opts}, @call_timeout)
          catch
            :exit, _ -> []
          end

        if local == [] do
          %{source: :empty, confidence: "low"}
        else
          %{source: :jsonl, confidence: "medium"}
        end

      _ ->
        %{source: :jsonl, confidence: "medium"}
    end
  end

  defp do_agent_rollups(opts) do
    case db_agent_rollups(opts) do
      {:ok, [_ | _] = rollups} -> rollups
      _ -> GenServer.call(__MODULE__, {:agent_rollups, opts}, @call_timeout)
    end
  end

  defp db_agent_rollups(opts) do
    since = Keyword.get(opts, :since)

    query =
      from(e in TraceEvent,
        where: not is_nil(e.session_id),
        group_by: fragment("COALESCE(?, ?)", e.agent_id, e.session_id),
        select: %{
          agent_id: fragment("COALESCE(?, ?)", e.agent_id, e.session_id),
          event_count: count(e.id),
          total_tokens:
            fragment(
              "SUM(COALESCE((?->>'inputTokens')::bigint, 0) + COALESCE((?->>'outputTokens')::bigint, 0))",
              e.metadata,
              e.metadata
            ),
          total_cost: fragment("SUM(COALESCE((?->>'costUsd')::double precision, 0))", e.metadata),
          last_tool:
            fragment(
              "COALESCE((ARRAY_REMOVE(array_agg(? ORDER BY ? DESC), NULL))[1], NULL)",
              e.tool,
              e.timestamp
            ),
          last_seen: max(e.timestamp)
        }
      )

    query =
      if match?(%DateTime{}, since) do
        where(query, [e], e.timestamp >= ^since)
      else
        query
      end

    rollups =
      query
      |> Repo.all()
      |> Enum.map(fn row ->
        agent_id = row.agent_id || "unknown"

        %{
          "agent" => String.slice(agent_id, 0, 12),
          "fullId" => agent_id,
          "events" => safe_int(row.event_count),
          "tokens" => safe_int(row.total_tokens),
          "spent" => safe_float(row.total_cost),
          "lastTool" => row.last_tool,
          "lastActivity" => format_datetime(row.last_seen)
        }
      end)
      |> Enum.sort_by(& &1["events"], :desc)

    {:ok, rollups}
  rescue
    _ -> {:error, :db_unavailable}
  end

  defp aggregate_agent_events(agent_id, events) do
    id = agent_id || "unknown"

    %{
      "agent" => String.slice(id, 0, 12),
      "fullId" => id,
      "events" => length(events),
      "tokens" =>
        Enum.reduce(events, 0, fn e, acc ->
          acc + (e.input_tokens || 0) + (e.output_tokens || 0)
        end),
      "spent" => Enum.reduce(events, 0.0, fn e, acc -> acc + (e.cost_usd || 0.0) end),
      "lastTool" => List.last(events)[:tool],
      "lastActivity" => List.last(events)[:timestamp]
    }
  end

  defp aggregate_task_events(task_id, events) do
    %{
      "task" => task_id || "unknown",
      "events" => length(events),
      "tokens" =>
        Enum.reduce(events, 0, fn e, acc ->
          acc + (e.input_tokens || 0) + (e.output_tokens || 0)
        end),
      "spent" => Enum.reduce(events, 0.0, fn e, acc -> acc + (e.cost_usd || 0.0) end),
      "lastActivity" => List.last(events)[:timestamp]
    }
  end

  defp maybe_filter_events_since(events, nil), do: events

  defp maybe_filter_events_since(events, %DateTime{} = since) do
    cutoff = DateTime.to_iso8601(since)
    Enum.filter(events, &((&1.timestamp || "") >= cutoff))
  end

  defp maybe_filter_events_since(events, _), do: events

  defp db_stats(opts) do
    with {:ok, sessions} <- db_all_sessions(opts) do
      {:ok,
       %{
         total_sessions: length(sessions),
         total_tool_calls: Enum.reduce(sessions, 0, &(Map.get(&1, :tool_count, 0) + &2)),
         total_cost: Enum.reduce(sessions, 0.0, &(Map.get(&1, :total_cost_usd, 0.0) + &2))
       }}
    end
  rescue
    _ -> {:error, :db_unavailable}
  end

  defp db_all_sessions(opts) do
    client_id = Keyword.get(opts, :client_id)
    since = Keyword.get(opts, :since)
    workspace = Keyword.get(opts, :workspace)
    limit = normalize_limit(Keyword.get(opts, :limit))

    query =
      from(e in TraceEvent,
        left_join: run in WorkflowRun,
        on: run.run_id == e.run_id,
        where: not is_nil(e.session_id),
        group_by: e.session_id,
        select: %{
          session_id: e.session_id,
          run_id:
            fragment(
              "COALESCE((ARRAY_REMOVE(array_agg(? ORDER BY ? DESC), NULL))[1], NULL)",
              e.run_id,
              e.timestamp
            ),
          first_seen: min(e.timestamp),
          last_seen: max(e.timestamp),
          last_tool:
            fragment(
              "COALESCE((ARRAY_REMOVE(array_agg(? ORDER BY ? DESC), NULL))[1], NULL)",
              e.tool,
              e.timestamp
            ),
          last_detail:
            fragment(
              "COALESCE((ARRAY_REMOVE(array_agg(? ORDER BY ? DESC), NULL))[1], NULL)",
              e.detail,
              e.timestamp
            ),
          tool_count: fragment("SUM(CASE WHEN ? = 'tool_call' THEN 1 ELSE 0 END)", e.event_type),
          total_input_tokens:
            fragment("SUM(COALESCE((?->>'inputTokens')::bigint, 0))", e.metadata),
          total_output_tokens:
            fragment("SUM(COALESCE((?->>'outputTokens')::bigint, 0))", e.metadata),
          total_cost_usd:
            fragment("SUM(COALESCE((?->>'costUsd')::double precision, 0))", e.metadata),
          model_id:
            fragment(
              "COALESCE((ARRAY_REMOVE(array_agg((?->>'model') ORDER BY ? DESC), NULL))[1], NULL)",
              e.metadata,
              e.timestamp
            ),
          execution_type:
            fragment(
              "COALESCE((ARRAY_REMOVE(array_agg(? ORDER BY ? DESC), NULL))[1], 'subscription')",
              run.execution_type,
              e.timestamp
            ),
          client_id:
            fragment(
              "COALESCE((ARRAY_REMOVE(array_agg(COALESCE(?, ?) ORDER BY ? DESC), NULL))[1], NULL)",
              e.client_id,
              run.client_id,
              e.timestamp
            ),
          workspace_path:
            fragment(
              "COALESCE((ARRAY_REMOVE(array_agg(? ORDER BY ? DESC), NULL))[1], NULL)",
              run.workspace_path,
              e.timestamp
            )
        }
      )

    query =
      if is_binary(client_id) and client_id != "" do
        where(
          query,
          [e, run],
          fragment("COALESCE(?, ?) = ?", e.client_id, run.client_id, ^client_id)
        )
      else
        query
      end

    query =
      if is_binary(workspace) and workspace != "" do
        where(query, [_e, run], run.workspace_path == ^workspace)
      else
        query
      end

    query =
      if match?(%DateTime{}, since) do
        where(query, [e, _run], e.timestamp >= ^since)
      else
        query
      end

    sessions =
      query
      |> Repo.all()
      |> Enum.map(&normalize_db_session/1)
      |> Enum.sort_by(&(&1.last_seen || ""), :desc)
      |> maybe_take_limit(limit)

    {:ok, sessions}
  rescue
    _ -> {:error, :db_unavailable}
  end

  defp stats_from_sessions(sessions) when is_list(sessions) do
    %{
      total_sessions: length(sessions),
      total_tool_calls: Enum.reduce(sessions, 0, &(Map.get(&1, :tool_count, 0) + &2)),
      total_cost: Enum.reduce(sessions, 0.0, &(Map.get(&1, :total_cost_usd, 0.0) + &2))
    }
  end

  defp db_sessions_for_run(run_prefix) when is_binary(run_prefix) and run_prefix != "" do
    like_pattern = "#{run_prefix}%"

    sessions =
      from(e in TraceEvent,
        left_join: run in WorkflowRun,
        on: run.run_id == e.run_id,
        where: not is_nil(e.session_id),
        where: like(e.run_id, ^like_pattern),
        group_by: e.session_id,
        select: %{
          session_id: e.session_id,
          run_id:
            fragment(
              "COALESCE((ARRAY_REMOVE(array_agg(? ORDER BY ? DESC), NULL))[1], NULL)",
              e.run_id,
              e.timestamp
            ),
          first_seen: min(e.timestamp),
          last_seen: max(e.timestamp),
          last_tool:
            fragment(
              "COALESCE((ARRAY_REMOVE(array_agg(? ORDER BY ? DESC), NULL))[1], NULL)",
              e.tool,
              e.timestamp
            ),
          tool_count: fragment("SUM(CASE WHEN ? = 'tool_call' THEN 1 ELSE 0 END)", e.event_type),
          total_input_tokens:
            fragment("SUM(COALESCE((?->>'inputTokens')::bigint, 0))", e.metadata),
          total_output_tokens:
            fragment("SUM(COALESCE((?->>'outputTokens')::bigint, 0))", e.metadata),
          total_cost_usd:
            fragment("SUM(COALESCE((?->>'costUsd')::double precision, 0))", e.metadata),
          model_id:
            fragment(
              "COALESCE((ARRAY_REMOVE(array_agg((?->>'model') ORDER BY ? DESC), NULL))[1], NULL)",
              e.metadata,
              e.timestamp
            ),
          execution_type:
            fragment(
              "COALESCE((ARRAY_REMOVE(array_agg(? ORDER BY ? DESC), NULL))[1], 'subscription')",
              run.execution_type,
              e.timestamp
            ),
          client_id:
            fragment(
              "COALESCE((ARRAY_REMOVE(array_agg(COALESCE(?, ?) ORDER BY ? DESC), NULL))[1], NULL)",
              e.client_id,
              run.client_id,
              e.timestamp
            ),
          workspace_path:
            fragment(
              "COALESCE((ARRAY_REMOVE(array_agg(? ORDER BY ? DESC), NULL))[1], NULL)",
              run.workspace_path,
              e.timestamp
            )
        },
        order_by: [desc: max(e.timestamp)]
      )
      |> Repo.all()
      |> Enum.map(&normalize_db_session/1)

    {:ok, sessions}
  rescue
    _ -> {:error, :db_unavailable}
  end

  defp db_sessions_for_run(_), do: {:ok, []}

  defp db_session_events(session_id, opts) do
    limit = Keyword.get(opts, :limit, @max_events_per_session)

    events =
      TraceEvent
      |> where([e], e.session_id == ^session_id)
      |> order_by([e], desc: e.timestamp)
      |> limit(^max(limit, 1))
      |> Repo.all()
      |> Enum.map(&trace_event_to_cost_event/1)

    {:ok, events}
  rescue
    _ -> {:error, :db_unavailable}
  end

  defp db_agent_events(agent_id, opts) do
    limit = Keyword.get(opts, :limit, @max_events_per_session)

    events =
      TraceEvent
      |> where([e], e.agent_id == ^agent_id)
      |> order_by([e], desc: e.timestamp)
      |> limit(^max(limit, 1))
      |> Repo.all()
      |> Enum.reverse()
      |> Enum.map(&trace_event_to_cost_event/1)

    {:ok, events}
  rescue
    _ -> {:error, :db_unavailable}
  end

  defp normalize_db_session(row) do
    session_id = Map.get(row, :session_id)
    input_tokens = safe_int(Map.get(row, :total_input_tokens))
    output_tokens = safe_int(Map.get(row, :total_output_tokens))

    %{
      session_id: session_id,
      short_id: String.slice(session_id || "", 0, 8),
      first_seen: format_datetime(Map.get(row, :first_seen)),
      last_seen: format_datetime(Map.get(row, :last_seen)),
      last_detail: Map.get(row, :last_detail),
      last_tool: Map.get(row, :last_tool),
      run_id: Map.get(row, :run_id),
      tool_count: safe_int(Map.get(row, :tool_count)),
      total_cost_usd: safe_float(Map.get(row, :total_cost_usd)),
      total_input_tokens: input_tokens,
      total_output_tokens: output_tokens,
      total_cache_read_tokens: 0,
      total_cache_creation_tokens: 0,
      execution_type: Map.get(row, :execution_type) || "subscription",
      model_id: Map.get(row, :model_id),
      client_id: Map.get(row, :client_id),
      workspace_path: Map.get(row, :workspace_path)
    }
  end

  defp trace_event_to_cost_event(e) do
    %{
      session_id: e.session_id,
      tool: e.tool,
      timestamp: format_datetime(e.timestamp),
      detail: e.detail,
      run_id: e.run_id,
      agent_id: e.agent_id,
      model_id: get_in(e.metadata || %{}, ["model"]),
      phase_index: get_in(e.metadata || %{}, ["phaseIndex"]),
      cost_usd: safe_float(get_in(e.metadata || %{}, ["costUsd"])),
      input_tokens: safe_int(get_in(e.metadata || %{}, ["inputTokens"])),
      output_tokens: safe_int(get_in(e.metadata || %{}, ["outputTokens"])),
      cache_read_tokens: safe_int(get_in(e.metadata || %{}, ["cacheReadTokens"])),
      cache_creation_tokens: safe_int(get_in(e.metadata || %{}, ["cacheCreationTokens"])),
      workspace_path:
        get_in(e.metadata || %{}, ["workspacePath"]) ||
          get_in(e.metadata || %{}, ["workspace_path"]) ||
          get_in(e.metadata || %{}, ["workspace"]) ||
          get_in(e.metadata || %{}, ["project"]),
      execution_type: nil
    }
  end

  # ---------------------------------------------------------------------------
  # Reading
  # ---------------------------------------------------------------------------

  defp full_read(state) do
    if File.exists?(state.file_path) do
      {sessions, session_evts, agent_evts, task_evts} =
        state.file_path
        |> File.stream!()
        |> Enum.reduce({%{}, %{}, %{}, %{}}, fn line, {sess, sevts, aevts, tevts} ->
          case parse_event(line) do
            nil ->
              {sess, sevts, aevts, tevts}

            event ->
              {update_session(sess, event), append_event(sevts, event),
               append_event_by_agent(aevts, event), append_event_by_task(tevts, event)}
          end
        end)

      file_size = File.stat!(state.file_path).size
      session_list = Map.values(sessions)

      %{
        state
        | sessions: sessions,
          events_by_session: session_evts,
          events_by_agent: agent_evts,
          events_by_task: task_evts,
          file_position: file_size,
          file_size: file_size,
          cumulative_sessions: length(session_list),
          cumulative_tool_calls: Enum.reduce(session_list, 0, &(&1.tool_count + &2)),
          cumulative_cost: Enum.reduce(session_list, 0.0, &(&1.total_cost_usd + &2))
      }
    else
      state
    end
  rescue
    e ->
      Logger.warning("CostEventReader: full_read failed: #{inspect(e)}")
      state
  end

  defp incremental_read(state) do
    if File.exists?(state.file_path) do
      case File.stat(state.file_path) do
        {:ok, %{size: size}} when size == state.file_size ->
          state

        {:ok, %{size: size}} when size < state.file_position ->
          # File was rotated/truncated — full re-read
          Logger.info("CostEventReader: file rotation detected, re-reading")
          full_read(%{state | file_position: 0, file_size: 0})

        {:ok, %{size: size}} ->
          read_from_position(state, size)

        {:error, _} ->
          state
      end
    else
      state
    end
  end

  defp read_from_position(state, new_size) do
    case :file.open(state.file_path, [:read, :binary]) do
      {:ok, fd} ->
        try do
          :file.position(fd, state.file_position)
          bytes_to_read = new_size - state.file_position

          case :file.read(fd, bytes_to_read) do
            {:ok, data} ->
              {sessions, session_evts, agent_evts, task_evts} =
                data
                |> String.split("\n", trim: true)
                |> Enum.reduce(
                  {state.sessions, state.events_by_session, state.events_by_agent,
                   state.events_by_task},
                  fn line, {sess, sevts, aevts, tevts} ->
                    case parse_event(line) do
                      nil ->
                        {sess, sevts, aevts, tevts}

                      event ->
                        {update_session(sess, event), append_event(sevts, event),
                         append_event_by_agent(aevts, event), append_event_by_task(tevts, event)}
                    end
                  end
                )

              new_session_count = map_size(sessions) - map_size(state.sessions)

              new_cost =
                Enum.reduce(Map.values(sessions), 0.0, &(&1.total_cost_usd + &2)) -
                  Enum.reduce(Map.values(state.sessions), 0.0, &(&1.total_cost_usd + &2))

              new_tool_calls =
                Enum.reduce(Map.values(sessions), 0, &(&1.tool_count + &2)) -
                  Enum.reduce(Map.values(state.sessions), 0, &(&1.tool_count + &2))

              %{
                state
                | sessions: sessions,
                  events_by_session: session_evts,
                  events_by_agent: agent_evts,
                  events_by_task: task_evts,
                  file_position: new_size,
                  file_size: new_size,
                  cumulative_sessions: state.cumulative_sessions + max(new_session_count, 0),
                  cumulative_tool_calls: state.cumulative_tool_calls + max(new_tool_calls, 0),
                  cumulative_cost: state.cumulative_cost + max(new_cost, 0.0)
              }

            _ ->
              state
          end
        after
          :file.close(fd)
        end

      {:error, _} ->
        state
    end
  rescue
    _ -> state
  end

  # ---------------------------------------------------------------------------
  # Event parsing and session aggregation
  # ---------------------------------------------------------------------------

  defp parse_event(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{"session" => session, "tool" => tool, "timestamp" => ts} = event}
      when is_binary(session) and is_binary(tool) ->
        %{
          session_id: session,
          tool: tool,
          timestamp: ts,
          detail: event["detail"],
          run_id: event["runId"] || event["run_id"],
          agent_id: event["agent_id"],
          task_id: event["taskId"],
          model_id: event["modelId"],
          phase_index: event["phaseIndex"],
          cost_usd: event["costUsd"] || 0.0,
          input_tokens: event["inputTokens"] || 0,
          output_tokens: event["outputTokens"] || 0,
          cache_read_tokens: event["cacheReadTokens"] || 0,
          cache_creation_tokens: event["cacheCreationTokens"] || 0,
          workspace_path:
            event["workspacePath"] ||
              event["workspace_path"] ||
              event["workspace"] ||
              event["project"] ||
              get_in(event, ["metadata", "workspacePath"]) ||
              get_in(event, ["metadata", "workspace_path"]) ||
              get_in(event, ["metadata", "workspace"]) ||
              get_in(event, ["metadata", "project"]),
          execution_type: event["executionType"] || infer_execution_type(event)
        }

      _ ->
        nil
    end
  end

  defp update_session(sessions, event) do
    Map.update(sessions, event.session_id, new_session(event), fn existing ->
      %{
        existing
        | last_seen: max_timestamp(existing.last_seen, event.timestamp),
          tool_count: existing.tool_count + 1,
          last_tool: event.tool,
          last_detail: event.detail || existing.last_detail,
          run_id: event.run_id || existing.run_id,
          model_id: event.model_id || existing.model_id,
          total_cost_usd: existing.total_cost_usd + (event.cost_usd || 0.0),
          total_input_tokens: existing.total_input_tokens + (event.input_tokens || 0),
          total_output_tokens: existing.total_output_tokens + (event.output_tokens || 0),
          total_cache_read_tokens:
            existing.total_cache_read_tokens + (event.cache_read_tokens || 0),
          total_cache_creation_tokens:
            existing.total_cache_creation_tokens + (event.cache_creation_tokens || 0),
          workspace_path: event.workspace_path || existing.workspace_path,
          execution_type: event.execution_type || existing.execution_type
      }
    end)
  end

  defp new_session(event) do
    %{
      session_id: event.session_id,
      short_id: String.slice(event.session_id, 0, 8),
      first_seen: event.timestamp,
      last_seen: event.timestamp,
      tool_count: 1,
      last_tool: event.tool,
      last_detail: event.detail,
      run_id: event.run_id,
      model_id: event.model_id,
      total_cost_usd: event.cost_usd || 0.0,
      total_input_tokens: event.input_tokens || 0,
      total_output_tokens: event.output_tokens || 0,
      total_cache_read_tokens: event.cache_read_tokens || 0,
      total_cache_creation_tokens: event.cache_creation_tokens || 0,
      workspace_path: event.workspace_path,
      execution_type: event.execution_type
    }
  end

  defp append_event(events_by_session, event) do
    Map.update(events_by_session, event.session_id, [event], fn existing ->
      (existing ++ [event]) |> Enum.take(-@max_events_per_session)
    end)
  end

  defp append_event_by_agent(events_by_agent, %{agent_id: nil}), do: events_by_agent
  defp append_event_by_agent(events_by_agent, %{agent_id: ""} = _event), do: events_by_agent

  defp append_event_by_agent(events_by_agent, %{agent_id: aid} = event) do
    Map.update(events_by_agent, aid, [event], fn existing ->
      (existing ++ [event]) |> Enum.take(-@max_events_per_session)
    end)
  end

  defp append_event_by_task(events_by_task, %{task_id: nil}), do: events_by_task
  defp append_event_by_task(events_by_task, %{task_id: ""}), do: events_by_task

  defp append_event_by_task(events_by_task, %{task_id: tid} = event) do
    Map.update(events_by_task, tid, [event], fn existing ->
      (existing ++ [event]) |> Enum.take(-@max_events_per_session)
    end)
  end

  defp max_timestamp(a, b) when is_binary(a) and is_binary(b), do: if(a >= b, do: a, else: b)
  defp max_timestamp(nil, b), do: b
  defp max_timestamp(a, nil), do: a

  # ---------------------------------------------------------------------------
  # Pruning and filtering
  # ---------------------------------------------------------------------------

  defp prune_old_sessions(state) do
    cutoff = DateTime.utc_now() |> DateTime.add(-@session_ttl_hours * 3600)
    cutoff_str = DateTime.to_iso8601(cutoff)

    {pruned_sessions, pruned_ids} =
      Enum.reduce(state.sessions, {%{}, []}, fn {id, sess}, {keep, drop} ->
        if (sess.last_seen || "") < cutoff_str do
          {keep, [id | drop]}
        else
          {Map.put(keep, id, sess), drop}
        end
      end)

    pruned_events = Map.drop(state.events_by_session, pruned_ids)
    %{state | sessions: pruned_sessions, events_by_session: pruned_events}
  end

  defp maybe_filter_since(sessions, nil), do: sessions

  defp maybe_filter_since(sessions, %DateTime{} = since) do
    cutoff = DateTime.to_iso8601(since)
    Enum.filter(sessions, &((&1.last_seen || "") >= cutoff))
  end

  defp maybe_filter_since(sessions, _), do: sessions

  defp maybe_filter_workspace(sessions, nil), do: sessions
  defp maybe_filter_workspace(sessions, ""), do: sessions

  defp maybe_filter_workspace(sessions, workspace) when is_binary(workspace) do
    Enum.filter(sessions, &(Map.get(&1, :workspace_path) == workspace))
  end

  defp maybe_filter_workspace(sessions, _), do: sessions

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval)

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp format_datetime(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp format_datetime(value) when is_binary(value), do: value
  defp format_datetime(_), do: nil

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

  defp maybe_take_limit(items, nil), do: items

  defp maybe_take_limit(items, limit) when is_integer(limit) and limit > 0,
    do: Enum.take(items, limit)

  defp maybe_take_limit(items, _), do: items

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: limit

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_limit(_), do: nil

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

  # Infer execution type when not explicitly set.
  # Claude Code subscription sessions typically have zero costUsd but non-zero tokens.
  # API sessions always report costUsd > 0.
  defp infer_execution_type(%{"costUsd" => cost}) when is_number(cost) and cost > 0, do: "api"

  defp infer_execution_type(%{"inputTokens" => inp}) when is_number(inp) and inp > 0,
    do: "subscription"

  defp infer_execution_type(_), do: nil
end
