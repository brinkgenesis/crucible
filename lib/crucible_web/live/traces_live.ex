defmodule CrucibleWeb.TracesLive do
  @moduledoc """
  LiveView for the Traces dashboard — real-time telemetry and regression monitoring.

  Provides three views:

    * **List view** — paginated, sortable table of workflow trace runs with summary
      stats (total runs, avg duration, cost, success rate, tokens) and a regression
      panel highlighting workflows whose latest run regressed vs. baseline.
    * **Detail view** — deep-dive into a single run with tabbed sub-views: timeline,
      tools, costs, events, files, tasks, agents, and MCP tool calls.
    * **Compare view** — side-by-side comparison of two runs for regression analysis.

  Runs are loaded from `Crucible.TraceReader` and filtered by time window,
  client, and workspace via `ScopeFilters`. The view auto-refreshes every 10 seconds
  and subscribes to PubSub topics (`orchestrator:traces`, `run:{id}`) for real-time
  event streaming.
  """

  use CrucibleWeb, :live_view

  alias Crucible.{Actionability, TraceReader}
  alias CrucibleWeb.Live.ScopeFilters

  @valid_sort_fields ~w(time cost duration tokens status)
  @valid_detail_tabs ~w(timeline tools costs events files tasks agents mcp)

  @refresh_interval 10_000

  @doc """
  Initializes the LiveView socket with default assigns and subscribes to PubSub.

  Sets up an auto-refresh timer and subscribes to `orchestrator:traces` for
  real-time trace event notifications when the socket is connected.
  """
  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      schedule_refresh(@refresh_interval)
      Phoenix.PubSub.subscribe(Crucible.PubSub, "orchestrator:traces")
    end

    {:ok,
     assign(socket,
       page_title: "Traces",
       current_path: "/traces",
       trace_runs: [],
       time_window: "7d",
       client_filter: ScopeFilters.all_scope(),
       workspace_filter: ScopeFilters.all_scope(),
       client_options: ScopeFilters.client_options([]),
       workspace_options: ScopeFilters.workspace_options([]),
       sort_by: "time",
       sort_dir: "desc",
       summary: %{
         total: 0,
         avg_duration_ms: 0,
         total_cost: 0.0,
         success_rate: 0.0,
         total_tokens: 0
       },
       regression_panel: %{total_workflows: 0, regressed: [], actionable: []},
       trace_source: %{source: :unknown, confidence: "low"},
       page: 1,
       per_page: 20,
       # Detail view
       selected: nil,
       run_summary: nil,
       trace_events: [],
       detail_tab: "timeline",
       event_filter: "",
       lifecycle_agents: [],
       phase_events: %{},
       session_logs: %{},
       expanded_logs: MapSet.new(),
       agent_transcripts: [],
       selected_runs: MapSet.new(),
       compare: nil,
       mcp_events: [],
       mcp_stats: []
     )}
  end

  @doc """
  Handles URL parameters to determine which view to render.

  Three clauses match in order:

    * `%{"left_run_id" => _, "right_run_id" => _}` — loads the compare view for two runs.
    * `%{"run_id" => _}` — loads the detail view for a single run, subscribing to its
      PubSub topic for real-time updates.
    * Catch-all — loads the paginated list view with summary stats and regression panel.

  All clauses extract time window, client, and workspace filters from query params.
  """
  @impl true
  def handle_params(
        %{"left_run_id" => left_run_id, "right_run_id" => right_run_id} = params,
        _uri,
        socket
      ) do
    window = normalize_window(Map.get(params, "window", "7d"))
    client_filter = ScopeFilters.normalize_param(params["client_id"])
    workspace_filter = ScopeFilters.normalize_param(params["workspace"])
    {client_options, workspace_options} = load_scope_options()

    left_summary = safe_call(fn -> TraceReader.run_summary(left_run_id) end, nil)
    right_summary = safe_call(fn -> TraceReader.run_summary(right_run_id) end, nil)

    compare =
      build_trace_compare(left_run_id, left_summary, right_run_id, right_summary)

    {:noreply,
     assign(socket,
       selected: nil,
       compare: compare,
       time_window: window,
       client_filter: client_filter,
       workspace_filter: workspace_filter,
       client_options: client_options,
       workspace_options: workspace_options,
       current_path:
         trace_compare_path(left_run_id, right_run_id, window, client_filter, workspace_filter),
       lifecycle_agents: [],
       phase_events: %{},
       session_logs: %{},
       expanded_logs: MapSet.new(),
       agent_transcripts: []
     )}
  end

  def handle_params(%{"run_id" => run_id} = params, _uri, socket) do
    # Subscribe to run-specific PubSub for real-time updates
    prev_id = socket.assigns[:selected]

    if prev_id && prev_id != run_id do
      Phoenix.PubSub.unsubscribe(Crucible.PubSub, "run:#{prev_id}")
    end

    if connected?(socket), do: Phoenix.PubSub.subscribe(Crucible.PubSub, "run:#{run_id}")

    window = normalize_window(Map.get(params, "window", "7d"))
    client_filter = ScopeFilters.normalize_param(params["client_id"])
    workspace_filter = ScopeFilters.normalize_param(params["workspace"])
    {client_options, workspace_options} = load_scope_options()

    # Single batched call: loads events once, derives summary + phases from same data,
    # parallelizes independent reads (lifecycle, transcripts, MCP).
    view = safe_call(fn -> TraceReader.detailed_run_view(run_id) end, %{})

    {:noreply,
     assign(socket,
       selected: run_id,
       compare: nil,
       time_window: window,
       client_filter: client_filter,
       workspace_filter: workspace_filter,
       client_options: client_options,
       workspace_options: workspace_options,
       run_summary: Map.get(view, :summary),
       trace_events: Map.get(view, :events, []),
       lifecycle_agents: Map.get(view, :lifecycle, []),
       phase_events: Map.get(view, :phase_events, %{}),
       session_logs: %{},
       expanded_logs: MapSet.new(),
       agent_transcripts: Map.get(view, :transcripts, []),
       mcp_events: Map.get(view, :mcp_events, []),
       mcp_stats: Map.get(view, :mcp_stats, []),
       current_path: trace_detail_path(run_id, window, client_filter, workspace_filter),
       detail_tab: "timeline"
     )}
  end

  def handle_params(params, _uri, socket) do
    window = normalize_window(Map.get(params, "window", "7d"))
    client_filter = ScopeFilters.normalize_param(params["client_id"])
    workspace_filter = ScopeFilters.normalize_param(params["workspace"])
    runs = load_trace_runs(window, client_filter, workspace_filter)
    summary = compute_summary(runs)
    trace_source = load_trace_source(window, client_filter, workspace_filter)
    {client_options, workspace_options} = load_scope_options()

    {:noreply,
     assign(socket,
       selected: nil,
       compare: nil,
       time_window: window,
       client_filter: client_filter,
       workspace_filter: workspace_filter,
       client_options: client_options,
       workspace_options: workspace_options,
       trace_runs: runs,
       summary: summary,
       regression_panel: build_regression_panel(runs),
       trace_source: trace_source,
       current_path: traces_index_path(window, client_filter, workspace_filter),
       lifecycle_agents: [],
       phase_events: %{},
       session_logs: %{},
       expanded_logs: MapSet.new(),
       agent_transcripts: []
     )}
  end

  @doc """
  Handles periodic refresh and real-time PubSub messages.

  The `:refresh` message reloads data for whichever view is active (compare, detail,
  or list). Trace and run event messages (`{:trace_event, _}`, `{:run_event, _, _, _}`)
  trigger a refresh. All other messages are ignored.
  """
  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh(@refresh_interval)

    if socket.assigns.compare do
      left_run_id = socket.assigns.compare.left_run_id
      right_run_id = socket.assigns.compare.right_run_id
      left_summary = safe_call(fn -> TraceReader.run_summary(left_run_id) end, nil)
      right_summary = safe_call(fn -> TraceReader.run_summary(right_run_id) end, nil)

      {:noreply,
       assign(
         socket,
         compare: build_trace_compare(left_run_id, left_summary, right_run_id, right_summary)
       )}
    else
      if socket.assigns.selected do
        run_id = socket.assigns.selected
        view = safe_call(fn -> TraceReader.detailed_run_view(run_id) end, %{})

        {:noreply,
         assign(socket,
           run_summary: Map.get(view, :summary, socket.assigns.run_summary),
           trace_events: Map.get(view, :events, socket.assigns.trace_events),
           lifecycle_agents: Map.get(view, :lifecycle, socket.assigns.lifecycle_agents),
           phase_events: Map.get(view, :phase_events, socket.assigns.phase_events),
           agent_transcripts: Map.get(view, :transcripts, socket.assigns.agent_transcripts)
         )}
      else
        runs =
          load_trace_runs(
            socket.assigns.time_window,
            socket.assigns.client_filter,
            socket.assigns.workspace_filter
          )

        {:noreply,
         assign(socket,
           trace_runs: runs,
           summary: compute_summary(runs),
           regression_panel: build_regression_panel(runs),
           trace_source:
             load_trace_source(
               socket.assigns.time_window,
               socket.assigns.client_filter,
               socket.assigns.workspace_filter
             )
         )}
      end
    end
  end

  def handle_info({:trace_event, _event}, socket) do
    send(self(), :refresh)
    {:noreply, socket}
  end

  # Real-time run event from PubSub "run:{id}"
  def handle_info({:run_event, _run_id, _event_type, _data}, socket) do
    send(self(), :refresh)
    {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @doc """
  Handles user-initiated UI events from the traces dashboard.

  Supported events:

    * `"toggle_select"` / `"select_all"` / `"deselect_all"` — manage multi-select for bulk operations.
    * `"delete_selected"` — deletes trace files for all selected runs and reloads the list.
    * `"create_trace_action_card"` — creates an actionability card for a regressed workflow.
    * `"set_window"` — changes the time window filter (24h, 7d, 30d, all).
    * `"set_scope_filters"` — updates client and workspace filters.
    * `"sort"` — toggles sort column and direction on the list view.
    * `"switch_tab"` — switches the active tab in the detail view.
    * `"toggle_session_log"` — expands/collapses a phase's session log, loading it lazily.
    * `"filter_events"` — filters trace events by a search query string.
    * `"page"` — navigates to a specific page in the paginated list.
  """
  @impl true
  def handle_event("toggle_select", %{"run_id" => run_id}, socket) do
    selected =
      if MapSet.member?(socket.assigns.selected_runs, run_id) do
        MapSet.delete(socket.assigns.selected_runs, run_id)
      else
        MapSet.put(socket.assigns.selected_runs, run_id)
      end

    {:noreply, assign(socket, selected_runs: selected)}
  end

  def handle_event("select_all", _, socket) do
    all_ids = Enum.map(socket.assigns.trace_runs, & &1.run_id) |> MapSet.new()
    {:noreply, assign(socket, selected_runs: all_ids)}
  end

  def handle_event("create_trace_action_card", params, socket) do
    workflow = Map.get(params, "workflow") || "unknown"
    latest_run_id = Map.get(params, "latest_run_id")
    baseline_run_id = Map.get(params, "baseline_run_id")
    summary = Map.get(params, "summary") || ""
    action = Map.get(params, "action") || "Investigate and remediate the regression."
    source_id = latest_run_id || workflow
    workspace = Map.get(params, "workspace")

    result =
      Actionability.create_action_card(%{
        source_kind: :trace,
        source_id: source_id,
        title: "Trace Regression: #{workflow}",
        summary: summary,
        action: action,
        workflow: "coding-sprint",
        client_id: ScopeFilters.query_value(socket.assigns.client_filter),
        workspace: workspace || ScopeFilters.query_value(socket.assigns.workspace_filter),
        signals: split_signals(summary),
        details: %{
          latest_run_id: latest_run_id,
          baseline_run_id: baseline_run_id
        },
        fingerprint: "trace-#{workflow}-#{latest_run_id || "none"}-#{baseline_run_id || "none"}"
      })

    case result do
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create action card: #{inspect(reason)}")}
    end
  end

  def handle_event("deselect_all", _, socket) do
    {:noreply, assign(socket, selected_runs: MapSet.new())}
  end

  def handle_event("delete_selected", _, socket) do
    base_dir = Application.get_env(:crucible, :base_dir, File.cwd!())
    selected = socket.assigns.selected_runs

    Enum.each(selected, fn run_id ->
      TraceReader.delete_run_files(run_id, base_dir)
    end)

    runs =
      load_trace_runs(
        socket.assigns.time_window,
        socket.assigns.client_filter,
        socket.assigns.workspace_filter
      )

    {:noreply,
     socket
     |> assign(
       selected_runs: MapSet.new(),
       trace_runs: runs,
       summary: compute_summary(runs),
       regression_panel: build_regression_panel(runs),
       trace_source:
         load_trace_source(
           socket.assigns.time_window,
           socket.assigns.client_filter,
           socket.assigns.workspace_filter
         )
     )}
  end

  def handle_event("set_window", %{"window" => window}, socket) do
    {:noreply,
     push_patch(
       socket,
       to:
         traces_index_path(window, socket.assigns.client_filter, socket.assigns.workspace_filter)
     )}
  end

  def handle_event("set_scope_filters", params, socket) do
    client_filter = ScopeFilters.normalize_param(params["client_id"])
    workspace_filter = ScopeFilters.normalize_param(params["workspace"])

    {:noreply,
     push_patch(
       socket,
       to: traces_index_path(socket.assigns.time_window, client_filter, workspace_filter)
     )}
  end

  def handle_event("sort", %{"by" => field}, socket) do
    if field in @valid_sort_fields do
      dir =
        if socket.assigns.sort_by == field and socket.assigns.sort_dir == "desc",
          do: "asc",
          else: "desc"

      {:noreply, assign(socket, sort_by: field, sort_dir: dir)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    if tab in @valid_detail_tabs do
      {:noreply, assign(socket, detail_tab: tab)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_session_log", %{"phase" => phase_id}, socket) do
    run_id = socket.assigns.selected
    expanded = socket.assigns.expanded_logs

    if MapSet.member?(expanded, phase_id) do
      {:noreply, assign(socket, expanded_logs: MapSet.delete(expanded, phase_id))}
    else
      logs = socket.assigns.session_logs

      logs =
        if Map.has_key?(logs, phase_id) do
          logs
        else
          content = safe_call(fn -> TraceReader.session_log(run_id, phase_id) end, nil)
          if content, do: Map.put(logs, phase_id, content), else: logs
        end

      {:noreply,
       assign(socket,
         expanded_logs: MapSet.put(expanded, phase_id),
         session_logs: logs
       )}
    end
  end

  def handle_event("filter_events", %{"q" => q}, socket) do
    {:noreply, assign(socket, event_filter: q)}
  end

  def handle_event("page", %{"page" => p}, socket) do
    {:noreply, assign(socket, page: String.to_integer(p) |> max(1))}
  end

  # ---------------------------------------------------------------------------
  # Data loading
  # ---------------------------------------------------------------------------

  defp load_trace_runs(window, client_filter, workspace_filter) do
    since = window_to_since(window)
    client_id = ScopeFilters.query_value(client_filter)
    workspace = ScopeFilters.query_value(workspace_filter)

    safe_call(
      fn -> TraceReader.list_runs(since: since, client_id: client_id, workspace: workspace) end,
      []
    )
    |> Enum.filter(fn run ->
      ScopeFilters.matches_workspace?(run_workspace(run), workspace_filter)
    end)
  end

  defp load_trace_source(window, client_filter, workspace_filter) do
    since = window_to_since(window)
    client_id = ScopeFilters.query_value(client_filter)
    workspace = ScopeFilters.query_value(workspace_filter)

    safe_call(
      fn ->
        TraceReader.list_runs_source(since: since, client_id: client_id, workspace: workspace)
      end,
      %{
        source: :unknown,
        confidence: "low"
      }
    )
  end

  defp load_scope_options do
    runs = safe_call(fn -> TraceReader.list_runs() end, [])

    client_options =
      runs
      |> Enum.map(&Map.get(&1, :client_id))
      |> ScopeFilters.client_options()

    workspace_options =
      runs
      |> Enum.map(&run_workspace/1)
      |> ScopeFilters.workspace_options()

    {client_options, workspace_options}
  end

  defp window_to_since("24h"), do: DateTime.utc_now() |> DateTime.add(-86_400)
  defp window_to_since("7d"), do: DateTime.utc_now() |> DateTime.add(-604_800)
  defp window_to_since("30d"), do: DateTime.utc_now() |> DateTime.add(-2_592_000)
  defp window_to_since(_), do: nil

  defp normalize_window("24h"), do: "24h"
  defp normalize_window("7d"), do: "7d"
  defp normalize_window("30d"), do: "30d"
  defp normalize_window("all"), do: "all"
  defp normalize_window(_), do: "7d"

  defp compute_summary(runs) do
    total = length(runs)

    if total == 0 do
      %{total: 0, avg_duration_ms: 0, total_cost: 0.0, success_rate: 0.0, total_tokens: 0}
    else
      done = Enum.count(runs, &(&1.status == "done"))
      avg_duration_ms = Enum.reduce(runs, 0, &((&1.duration_ms || 0) + &2)) / total

      %{
        total: total,
        avg_duration_ms: round(avg_duration_ms),
        total_cost: Enum.reduce(runs, 0.0, &((&1.total_cost_usd || 0.0) + &2)),
        success_rate: if(total > 0, do: done / total, else: 0.0),
        total_tokens: Enum.reduce(runs, 0, &((&1.total_tokens || 0) + &2))
      }
    end
  end

  defp schedule_refresh(interval), do: Process.send_after(self(), :refresh, interval)

  # ---------------------------------------------------------------------------
  # Sorting
  # ---------------------------------------------------------------------------

  defp sort_runs(runs, sort_by, sort_dir) do
    sorter =
      case sort_by do
        "time" -> &(&1.started_at || "")
        "cost" -> &(&1.total_cost_usd || 0.0)
        "duration" -> &(&1.duration_ms || 0)
        "tokens" -> &(&1.total_tokens || 0)
        "status" -> &(&1.status || "")
        _ -> &(&1.started_at || "")
      end

    sorted = Enum.sort_by(runs, sorter)
    if sort_dir == "desc", do: Enum.reverse(sorted), else: sorted
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @doc """
  Renders the traces dashboard.

  Delegates to one of three sub-components based on socket state:
  `compare_view/1` (when `@compare` is set), `detail_view/1` (when `@selected`
  is set), or `list_view/1` (default).
  """
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <%= if @compare do %>
          <.compare_view
            compare={@compare}
            time_window={@time_window}
            client_filter={@client_filter}
            workspace_filter={@workspace_filter}
          />
        <% else %>
          <%= if @selected do %>
            <.detail_view
              run_id={@selected}
              time_window={@time_window}
              client_filter={@client_filter}
              workspace_filter={@workspace_filter}
              run_summary={@run_summary}
              trace_events={@trace_events}
              detail_tab={@detail_tab}
              event_filter={@event_filter}
              lifecycle_agents={@lifecycle_agents}
              phase_events={@phase_events}
              session_logs={@session_logs}
              expanded_logs={@expanded_logs}
              agent_transcripts={@agent_transcripts}
              mcp_events={@mcp_events}
              mcp_stats={@mcp_stats}
            />
          <% else %>
            <.list_view
              trace_runs={@trace_runs}
              time_window={@time_window}
              client_filter={@client_filter}
              workspace_filter={@workspace_filter}
              client_options={@client_options}
              workspace_options={@workspace_options}
              sort_by={@sort_by}
              sort_dir={@sort_dir}
              summary={@summary}
              regression_panel={@regression_panel}
              trace_source={@trace_source}
              page={@page}
              per_page={@per_page}
              selected_runs={@selected_runs}
            />
          <% end %>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # List view
  # ---------------------------------------------------------------------------

  attr :trace_runs, :list, required: true
  attr :time_window, :string, required: true
  attr :client_filter, :string, required: true
  attr :workspace_filter, :string, required: true
  attr :client_options, :list, required: true
  attr :workspace_options, :list, required: true
  attr :sort_by, :string, required: true
  attr :sort_dir, :string, required: true
  attr :summary, :map, required: true
  attr :regression_panel, :map, required: true
  attr :trace_source, :map, required: true
  attr :page, :integer, required: true
  attr :per_page, :integer, required: true
  attr :selected_runs, :any, required: true

  defp list_view(assigns) do
    sorted = sort_runs(assigns.trace_runs, assigns.sort_by, assigns.sort_dir)
    total_pages = max(ceil(length(sorted) / assigns.per_page), 1)

    page_runs =
      sorted |> Enum.drop((assigns.page - 1) * assigns.per_page) |> Enum.take(assigns.per_page)

    assigns = assign(assigns, sorted: sorted, page_runs: page_runs, total_pages: total_pages)

    ~H"""
    <%!-- Page header --%>
    <div class="flex flex-col md:flex-row md:items-end justify-between gap-4 mb-2">
      <div>
        <div class="flex items-center gap-2 mb-1">
          <span class="w-2 h-2 bg-[#00eefc] animate-pulse" />
          <span class="text-[#00eefc] font-mono text-[10px] tracking-[0.3em] uppercase">
            REAL-TIME TELEMETRY &amp; REGRESSION MONITORING
          </span>
        </div>
        <h1 class="text-3xl md:text-4xl font-headline font-bold text-white tracking-tighter uppercase">
          TRACE_ANALYTICS<span class="text-[#ffa44c]">.SYS</span>
        </h1>
      </div>
      <div class="flex items-center gap-3 bg-surface-container-low p-2 border border-[#494847]/10">
        <div class="flex flex-col items-end pr-4 border-r border-[#494847]/20">
          <span class="font-mono text-[10px] text-[#777575]">TRACES</span>
          <span class="font-mono text-sm text-[#00eefc] font-bold">{@summary.total}</span>
        </div>
        <div class="flex flex-col items-end">
          <span class="font-mono text-[10px] text-[#777575]">STATUS</span>
          <span class="font-mono text-sm text-[#ffa44c] font-bold">SYNCHRONIZED</span>
        </div>
      </div>
    </div>

    <.scope_filter_bar
      event="set_scope_filters"
      client_filter={@client_filter}
      workspace_filter={@workspace_filter}
      client_options={@client_options}
      workspace_options={@workspace_options}
    />

    <%!-- Time window filter + source + bulk actions --%>
    <div class="flex items-center gap-4 flex-wrap">
      <div class="flex gap-1">
        <button
          :for={w <- ["24h", "7d", "30d", "all"]}
          phx-click="set_window"
          phx-value-window={w}
          class={[
            "px-3 py-1.5 font-mono text-[10px] tracking-widest transition-all",
            if(@time_window == w,
              do: "bg-[#ffa44c] text-black font-bold",
              else:
                "border border-[#494847]/30 text-neutral-500 hover:border-[#00eefc] hover:text-[#00eefc]"
            )
          ]}
        >
          {String.upcase(w)}
        </button>
      </div>
      <span class={[
        "px-1.5 py-0.5 text-[8px] font-mono font-bold",
        case @trace_source.confidence do
          "high" -> "bg-[#00FF41]/10 text-[#00FF41] border border-[#00FF41]/30"
          "medium" -> "bg-[#ffa44c]/10 text-[#ffa44c] border border-[#ffa44c]/30"
          _ -> "bg-[#ff7351]/10 text-[#ff7351] border border-[#ff7351]/30"
        end
      ]}>
        SOURCE: {String.upcase(to_string(source_label(@trace_source.source)))}
      </span>
      <div :if={MapSet.size(@selected_runs) > 0} class="flex items-center gap-2">
        <.tactical_button
          variant="danger"
          phx-click="delete_selected"
          data-confirm={"Delete #{MapSet.size(@selected_runs)} run(s)? This cannot be undone."}
        >
          <span class="material-symbols-outlined text-xs mr-1">delete</span>
          DELETE {MapSet.size(@selected_runs)} RUN(S)
        </.tactical_button>
        <.tactical_button variant="ghost" phx-click="deselect_all">CLEAR</.tactical_button>
      </div>
    </div>

    <%!-- Bento Grid Stats --%>
    <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
      <div class="bg-surface-container-low border-t-2 border-[#00eefc] p-4 hud-border flex flex-col justify-between min-h-[140px]">
        <div class="flex justify-between items-start">
          <span class="font-mono text-[10px] text-[#00eefc] tracking-widest">TOTAL_RUNS</span>
          <span class="material-symbols-outlined text-[#00eefc] opacity-50">data_exploration</span>
        </div>
        <div class="text-4xl font-headline font-black text-white">{@summary.total}</div>
      </div>
      <div class="bg-surface-container-low border-t-2 border-[#ffa44c] p-4 hud-border flex flex-col justify-between min-h-[140px]">
        <div class="flex justify-between items-start">
          <span class="font-mono text-[10px] text-[#ffa44c] tracking-widest">AVG_DURATION</span>
          <span class="material-symbols-outlined text-[#ffa44c] opacity-50">timer</span>
        </div>
        <div class="text-4xl font-headline font-black text-white">
          {format_duration_ms(@summary.avg_duration_ms)}
        </div>
      </div>
      <div class="bg-surface-container-low border-t-2 border-[#ffa44c] p-4 hud-border flex flex-col justify-between min-h-[140px]">
        <div class="flex justify-between items-start">
          <span class="font-mono text-[10px] text-[#ffa44c] tracking-widest">TOTAL_COST</span>
          <span class="material-symbols-outlined text-[#ffa44c] opacity-50">payments</span>
        </div>
        <div class="text-4xl font-headline font-black text-white">
          ${Float.round(@summary.total_cost * 1.0, 2)}
        </div>
      </div>
      <div class="bg-surface-container-low border-t-2 border-[#ff725e] p-4 hud-border relative overflow-hidden">
        <div class="relative z-10 flex flex-col h-full justify-between">
          <div class="flex justify-between items-start">
            <span class="font-mono text-[10px] text-[#ff725e] tracking-widest">SUCCESS_RATE</span>
            <span class="material-symbols-outlined text-[#ff725e] opacity-50">verified_user</span>
          </div>
          <div class="flex items-end gap-4">
            <div class="text-4xl font-headline font-black text-white">
              {Float.round(@summary.success_rate * 100, 0)}%
            </div>
            <div class="flex-1 mb-2">
              <div class="h-2 w-full bg-surface-container-highest">
                <div
                  class="h-full bg-[#ff725e] shadow-[0_0_10px_rgba(255,114,94,0.5)]"
                  style={"width: #{Float.round(@summary.success_rate * 100, 0)}%"}
                />
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <%!-- Regression Panel --%>
    <div
      :if={@regression_panel.regressed != [] or @regression_panel.actionable != []}
      class="bg-surface-container-low border border-[#494847]/10 p-6 hud-border relative"
    >
      <div class="absolute top-0 right-0 p-2 bg-[#ff725e]/10 border-b border-l border-[#ff725e]/20">
        <span class="font-mono text-[10px] text-[#ff725e] animate-pulse font-bold tracking-tighter">
          REGRESSION_DETECTED
        </span>
      </div>
      <h3 class="font-headline text-lg font-bold text-white uppercase mb-6 flex items-center gap-2">
        <span class="w-1.5 h-6 bg-[#ff725e]" /> REGRESSION_ANALYSIS
      </h3>
      <div :if={@regression_panel.regressed != []} class="space-y-2 mb-4">
        <div class="text-[10px] text-[#ff725e] font-mono font-bold uppercase">REGRESSIONS</div>
        <div
          :for={row <- @regression_panel.regressed}
          class="flex items-center justify-between gap-3 p-3 bg-surface-container border border-[#494847]/10"
        >
          <div class="min-w-0">
            <span class="font-mono text-[11px] text-white font-bold">{row.workflow}</span>
            <span class="text-[#777575] text-[10px] font-mono ml-2">{row.summary}</span>
          </div>
          <.link
            :if={row.latest_run_id && row.baseline_run_id}
            patch={
              trace_compare_path(
                row.latest_run_id,
                row.baseline_run_id,
                @time_window,
                @client_filter,
                @workspace_filter
              )
            }
            class="px-2 py-1 border border-[#494847]/30 text-[#777575] font-mono text-[9px] hover:text-[#00eefc] hover:border-[#00eefc] transition-all"
          >
            COMPARE
          </.link>
        </div>
      </div>
      <div :if={@regression_panel.actionable != []} class="space-y-2">
        <div class="text-[10px] text-[#00eefc] font-mono font-bold uppercase">ACTIONABILITY</div>
        <div
          :for={row <- @regression_panel.actionable}
          class="flex items-center justify-between gap-3 p-3 bg-surface-container border border-[#494847]/10"
        >
          <div class="min-w-0">
            <span class="font-mono text-[11px] text-white font-bold">{row.workflow}</span>
            <span class="text-[#777575] text-[10px] font-mono ml-2">{row.action}</span>
          </div>
          <div class="flex items-center gap-2 shrink-0">
            <.link
              :if={row.latest_run_id && row.baseline_run_id}
              patch={
                trace_compare_path(
                  row.latest_run_id,
                  row.baseline_run_id,
                  @time_window,
                  @client_filter,
                  @workspace_filter
                )
              }
              class="px-2 py-1 border border-[#494847]/30 text-[#777575] font-mono text-[9px] hover:text-[#00eefc] hover:border-[#00eefc] transition-all"
            >
              COMPARE
            </.link>
            <.tactical_button
              phx-click="create_trace_action_card"
              phx-value-workflow={row.workflow}
              phx-value-summary={row.summary}
              phx-value-action={row.action}
              phx-value-latest_run_id={row.latest_run_id}
              phx-value-baseline_run_id={row.baseline_run_id}
              phx-value-workspace={row.workspace}
            >
              CREATE_CARD
            </.tactical_button>
          </div>
        </div>
      </div>
    </div>

    <%!-- Runs table --%>
    <div :if={@trace_runs == []} class="text-center py-12">
      <span class="material-symbols-outlined text-6xl text-[#494847]/30">search</span>
      <p class="text-[10px] font-mono text-neutral-500 mt-2">NO_TRACES_FOUND_FOR_THIS_WINDOW</p>
    </div>

    <div
      :if={@trace_runs != []}
      class="bg-surface-container-low border border-[#494847]/10 hud-border overflow-hidden"
    >
      <div class="p-6 border-b border-[#494847]/10 flex justify-between items-center bg-surface-container">
        <h3 class="font-headline text-lg font-bold text-white uppercase flex items-center gap-2">
          <span class="w-1.5 h-6 bg-[#ffa44c]" /> DETAILED_EXECUTION_LOG
        </h3>
      </div>
      <div class="overflow-x-auto">
        <table class="w-full text-left font-mono text-[11px]">
          <thead>
            <tr class="bg-black/40 text-[#777575] border-b border-[#494847]/10 uppercase tracking-widest">
              <th class="px-4 py-4 font-normal w-8">
                <input
                  type="checkbox"
                  class="w-3 h-3 accent-[#ffa44c] bg-surface-container-highest border-[#494847]"
                  phx-click={
                    if MapSet.size(@selected_runs) == length(@page_runs) && @page_runs != [],
                      do: "deselect_all",
                      else: "select_all"
                  }
                  checked={MapSet.size(@selected_runs) == length(@trace_runs) && @trace_runs != []}
                />
              </th>
              <th
                class="px-4 py-4 font-normal cursor-pointer hover:text-[#00eefc]"
                phx-click="sort"
                phx-value-by="time"
              >
                RUN_ID {sort_indicator("time", @sort_by, @sort_dir)}
              </th>
              <th class="px-4 py-4 font-normal">WORKFLOW</th>
              <th
                class="px-4 py-4 font-normal text-right cursor-pointer hover:text-[#00eefc]"
                phx-click="sort"
                phx-value-by="duration"
              >
                DURATION {sort_indicator("duration", @sort_by, @sort_dir)}
              </th>
              <th
                class="px-4 py-4 font-normal text-right cursor-pointer hover:text-[#00eefc]"
                phx-click="sort"
                phx-value-by="tokens"
              >
                TOKENS {sort_indicator("tokens", @sort_by, @sort_dir)}
              </th>
              <th class="px-4 py-4 font-normal">EVENTS</th>
              <th
                class="px-4 py-4 font-normal cursor-pointer hover:text-[#00eefc]"
                phx-click="sort"
                phx-value-by="status"
              >
                STATUS {sort_indicator("status", @sort_by, @sort_dir)}
              </th>
              <th class="px-4 py-4 font-normal">STARTED</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-[#494847]/5">
            <tr :for={run <- @page_runs} class="hover:bg-[#00eefc]/5 transition-colors">
              <td class="px-4 py-3">
                <input
                  type="checkbox"
                  class="w-3 h-3 accent-[#ffa44c] bg-surface-container-highest border-[#494847]"
                  phx-click="toggle_select"
                  phx-value-run_id={run.run_id}
                  checked={MapSet.member?(@selected_runs, run.run_id)}
                />
              </td>
              <td class="px-4 py-3">
                <.link
                  patch={
                    trace_detail_path(run.run_id, @time_window, @client_filter, @workspace_filter)
                  }
                  class="text-white font-bold hover:text-[#00eefc] transition-colors"
                >
                  {String.slice(run.run_id, 0, 12)}
                </.link>
              </td>
              <td class="px-4 py-3 text-white">{run.workflow_name}</td>
              <td class="px-4 py-3 text-right text-[#00eefc]">
                {format_duration_ms(run.duration_ms || 0)}
              </td>
              <td class="px-4 py-3 text-right text-white">{format_tokens(run.total_tokens || 0)}</td>
              <td class="px-4 py-3 text-[#777575]">{run.event_count}</td>
              <td class="px-4 py-3">
                <span class={[
                  "px-2 py-0.5 border font-bold uppercase text-[9px]",
                  case to_string(run.status) do
                    s when s in ["done", "completed"] ->
                      "bg-[#00FF41]/10 text-[#00FF41] border-[#00FF41]/30"

                    "failed" ->
                      "bg-[#ff725e]/20 text-[#ff725e] border-[#ff725e]/30"

                    s when s in ["running", "in_progress"] ->
                      "bg-[#ffa44c]/20 text-[#ffa44c] border-[#ffa44c]/30"

                    _ ->
                      "bg-[#494847]/10 text-[#777575] border-[#494847]/30"
                  end
                ]}>
                  {run.status}
                </span>
              </td>
              <td class="px-4 py-3 text-[#777575]">{format_time(run.started_at)}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <div class="p-4 bg-black/40 border-t border-[#494847]/10 flex justify-center gap-4">
        <button
          :if={@page > 1}
          phx-click="page"
          phx-value-page={@page - 1}
          class="text-[#777575] hover:text-white transition-colors"
        >
          <span class="material-symbols-outlined">chevron_left</span>
        </button>
        <div class="flex items-center gap-4 font-mono text-[10px]">
          <span
            :for={p <- Enum.to_list(max(1, @page - 2)..min(@total_pages, @page + 2))}
            phx-click="page"
            phx-value-page={p}
            class={[
              "cursor-pointer",
              if(p == @page,
                do: "text-white bg-[#ffa44c]/20 px-2 py-0.5 border border-[#ffa44c]/40",
                else: "text-[#777575] hover:text-white"
              )
            ]}
          >
            PAGE_{String.pad_leading(to_string(p), 2, "0")}
          </span>
        </div>
        <button
          :if={@page < @total_pages}
          phx-click="page"
          phx-value-page={@page + 1}
          class="text-[#777575] hover:text-white transition-colors"
        >
          <span class="material-symbols-outlined">chevron_right</span>
        </button>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Compare view
  # ---------------------------------------------------------------------------

  attr :compare, :map, required: true
  attr :time_window, :string, required: true
  attr :client_filter, :string, required: true
  attr :workspace_filter, :string, required: true

  defp compare_view(assigns) do
    ~H"""
    <div class="flex items-center gap-4">
      <.link
        patch={traces_index_path(@time_window, @client_filter, @workspace_filter)}
        class="px-3 py-1.5 border border-[#494847]/30 text-[#777575] font-mono text-[10px] hover:text-[#00eefc] hover:border-[#00eefc] transition-all flex items-center gap-1"
      >
        <span class="material-symbols-outlined text-sm">arrow_back</span> BACK
      </.link>
      <div>
        <h1 class="text-2xl font-headline font-bold text-white tracking-tighter uppercase">
          TRACE_COMPARE
        </h1>
        <div class="text-[10px] text-[#777575] font-mono">
          {@compare.left_run_id} VS {@compare.right_run_id}
        </div>
      </div>
    </div>

    <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
      <div class="bg-surface-container-low p-5 hud-border border-t-2 border-[#ffa44c]">
        <div class="text-[9px] font-mono text-[#ffa44c]/70 uppercase mb-2">DURATION_DELTA</div>
        <div class={[
          "text-2xl font-headline font-bold",
          hud_delta_class(@compare.totals.duration_delta_ms)
        ]}>
          {format_signed_duration(@compare.totals.duration_delta_ms)}
        </div>
      </div>
      <div class="bg-surface-container-low p-5 hud-border border-t-2 border-[#00eefc]">
        <div class="text-[9px] font-mono text-[#00eefc]/70 uppercase mb-2">TOKEN_DELTA</div>
        <div class={[
          "text-2xl font-headline font-bold",
          hud_delta_class(@compare.totals.tokens_delta)
        ]}>
          {format_signed_tokens(@compare.totals.tokens_delta)}
        </div>
      </div>
      <div class="bg-surface-container-low p-5 hud-border border-t-2 border-[#ff725e]">
        <div class="text-[9px] font-mono text-[#ff725e]/70 uppercase mb-2">COST_DELTA</div>
        <div class={["text-2xl font-headline font-bold", hud_delta_class(@compare.totals.cost_delta)]}>
          {format_signed_cost(@compare.totals.cost_delta)}
        </div>
      </div>
    </div>

    <div class="bg-surface-container-low border border-[#494847]/10 hud-border overflow-hidden">
      <div class="p-6 border-b border-[#494847]/10 bg-surface-container">
        <h3 class="font-headline text-lg font-bold text-white uppercase flex items-center gap-2">
          <span class="w-1.5 h-6 bg-[#ffa44c]" /> PHASE_BY_PHASE
        </h3>
      </div>
      <div :if={@compare.rows == []} class="text-center py-8">
        <span class="material-symbols-outlined text-4xl text-[#494847]/30">compare_arrows</span>
        <p class="text-[10px] font-mono text-neutral-500 mt-2">NO_PHASE_OVERLAP_FOUND</p>
      </div>
      <div :if={@compare.rows != []} class="overflow-x-auto">
        <table class="w-full text-left font-mono text-[11px]">
          <thead>
            <tr class="bg-black/40 text-[#777575] border-b border-[#494847]/10 uppercase tracking-widest">
              <th class="px-4 py-3 font-normal">PHASE</th>
              <th class="px-4 py-3 font-normal text-right">LATEST_DUR</th>
              <th class="px-4 py-3 font-normal text-right">BASE_DUR</th>
              <th class="px-4 py-3 font-normal text-right">Δ_DUR</th>
              <th class="px-4 py-3 font-normal text-right">LATEST_TOK</th>
              <th class="px-4 py-3 font-normal text-right">BASE_TOK</th>
              <th class="px-4 py-3 font-normal text-right">Δ_TOK</th>
              <th class="px-4 py-3 font-normal text-right">LATEST_$</th>
              <th class="px-4 py-3 font-normal text-right">BASE_$</th>
              <th class="px-4 py-3 font-normal text-right">Δ_$</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-[#494847]/5">
            <tr :for={row <- @compare.rows} class="hover:bg-[#00eefc]/5 transition-colors">
              <td class="px-4 py-3 text-white font-bold">{row.phase_name}</td>
              <td class="px-4 py-3 text-right text-white">
                {format_duration_ms(row.left_duration_ms)}
              </td>
              <td class="px-4 py-3 text-right text-[#777575]">
                {format_duration_ms(row.right_duration_ms)}
              </td>
              <td class={["px-4 py-3 text-right", hud_delta_class(row.duration_delta_ms)]}>
                {format_signed_duration(row.duration_delta_ms)}
              </td>
              <td class="px-4 py-3 text-right text-white">{format_tokens(row.left_tokens)}</td>
              <td class="px-4 py-3 text-right text-[#777575]">{format_tokens(row.right_tokens)}</td>
              <td class={["px-4 py-3 text-right", hud_delta_class(row.tokens_delta)]}>
                {format_signed_tokens(row.tokens_delta)}
              </td>
              <td class="px-4 py-3 text-right text-white">${Float.round(row.left_cost_usd, 4)}</td>
              <td class="px-4 py-3 text-right text-[#777575]">
                ${Float.round(row.right_cost_usd, 4)}
              </td>
              <td class={["px-4 py-3 text-right", hud_delta_class(row.cost_delta)]}>
                {format_signed_cost(row.cost_delta)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Detail view
  # ---------------------------------------------------------------------------

  attr :run_id, :string, required: true
  attr :time_window, :string, required: true
  attr :client_filter, :string, required: true
  attr :workspace_filter, :string, required: true
  attr :run_summary, :map, default: nil
  attr :trace_events, :list, required: true
  attr :detail_tab, :string, required: true
  attr :event_filter, :string, required: true
  attr :lifecycle_agents, :list, required: true
  attr :phase_events, :map, required: true
  attr :session_logs, :map, required: true
  attr :expanded_logs, :any, required: true
  attr :agent_transcripts, :list, required: true
  attr :mcp_events, :list, required: true
  attr :mcp_stats, :list, required: true

  defp detail_view(assigns) do
    workflow_name = (assigns.run_summary && assigns.run_summary[:workflow_name]) || assigns.run_id
    total_tokens = compute_total_tokens(assigns.run_summary, assigns.agent_transcripts)
    assigns = assign(assigns, workflow_name: workflow_name, total_tokens: total_tokens)

    ~H"""
    <div class="flex items-center gap-4">
      <.link
        patch={traces_index_path(@time_window, @client_filter, @workspace_filter)}
        class="px-3 py-1.5 border border-[#494847]/30 text-[#777575] font-mono text-[10px] hover:text-[#00eefc] hover:border-[#00eefc] transition-all flex items-center gap-1"
      >
        <span class="material-symbols-outlined text-sm">arrow_back</span> BACK
      </.link>
      <div>
        <h1 class="text-2xl font-headline font-bold text-white tracking-tighter uppercase">
          {format_phase_name_label(@workflow_name)}
        </h1>
        <div class="text-[10px] text-[#777575] font-mono">{String.slice(@run_id, 0, 16)}</div>
      </div>
    </div>

    <%!-- Summary header --%>
    <div :if={@run_summary} class="grid grid-cols-2 md:grid-cols-5 gap-3">
      <div class="bg-surface-container-low p-4 hud-border border-t-2 border-[#ffa44c]">
        <div class="text-[9px] font-mono text-[#ffa44c]/70 uppercase">DURATION</div>
        <div class="text-xl font-bold font-mono text-white">
          {format_duration_ms(@run_summary.duration_ms)}
        </div>
      </div>
      <div class="bg-surface-container-low p-4 hud-border border-t-2 border-[#00eefc]">
        <div class="text-[9px] font-mono text-[#00eefc]/70 uppercase">PHASES</div>
        <div class="text-xl font-bold font-mono text-white">{@run_summary.phase_count}</div>
      </div>
      <div class="bg-surface-container-low p-4 hud-border border-t-2 border-[#00eefc]">
        <div class="text-[9px] font-mono text-[#00eefc]/70 uppercase">AGENTS</div>
        <div class="text-xl font-bold font-mono text-white">{@run_summary.agent_count}</div>
      </div>
      <div class="bg-surface-container-low p-4 hud-border border-t-2 border-[#ffa44c]">
        <div class="text-[9px] font-mono text-[#ffa44c]/70 uppercase">INPUT_TOKENS</div>
        <div class="text-xl font-bold font-mono text-white">{format_tokens(@total_tokens.input)}</div>
      </div>
      <div class="bg-surface-container-low p-4 hud-border border-t-2 border-[#ff725e]">
        <div class="text-[9px] font-mono text-[#ff725e]/70 uppercase">OUTPUT_TOKENS</div>
        <div class="text-xl font-bold font-mono text-white">
          {format_tokens(@total_tokens.output)}
        </div>
      </div>
    </div>

    <%!-- Tabs --%>
    <div class="flex gap-1 flex-wrap border-b border-[#494847]/20 pb-1">
      <button
        :for={{id, label, _icon} <- detail_tabs()}
        phx-click="switch_tab"
        phx-value-tab={id}
        class={[
          "px-4 py-2 font-mono text-[10px] tracking-widest uppercase transition-all",
          if(@detail_tab == id,
            do: "bg-[#ffa44c]/10 text-[#ffa44c] border-b-2 border-[#ffa44c]",
            else: "text-[#777575] hover:text-[#00eefc] hover:bg-[#00eefc]/5"
          )
        ]}
      >
        {label}
      </button>
    </div>

    <%!-- Tab content --%>
    <div :if={@detail_tab == "timeline"} class="space-y-2">
      <.phase_timeline
        phases={(@run_summary && @run_summary.phases) || []}
        total_duration_ms={(@run_summary && @run_summary.duration_ms) || 0}
      />
    </div>

    <div :if={@detail_tab == "tools"} class="space-y-2">
      <.tool_distribution tools={(@run_summary && @run_summary.tools) || []} />
    </div>

    <div :if={@detail_tab == "costs"} class="space-y-2">
      <.cost_breakdown
        costs={(@run_summary && @run_summary.costs) || []}
        agent_transcripts={@agent_transcripts}
      />
    </div>

    <div :if={@detail_tab == "events"}>
      <.event_log events={@trace_events} filter={@event_filter} />
    </div>

    <div :if={@detail_tab == "files"} class="space-y-2">
      <.files_view files={(@run_summary && @run_summary.files) || []} />
    </div>

    <div :if={@detail_tab == "tasks"} class="space-y-2">
      <.tasks_view tasks={(@run_summary && @run_summary[:tasks]) || []} />
    </div>

    <div :if={@detail_tab == "agents"} class="space-y-4">
      <.agents_view
        run_id={@run_id}
        run_summary={@run_summary}
        lifecycle_agents={@lifecycle_agents}
        phase_events={@phase_events}
        session_logs={@session_logs}
        expanded_logs={@expanded_logs}
        agent_transcripts={@agent_transcripts}
      />
    </div>

    <div :if={@detail_tab == "mcp"} class="space-y-6">
      <div :if={@mcp_stats == []} class="text-center py-12">
        <span class="material-symbols-outlined text-4xl text-[#494847]/30">api</span>
        <p class="font-mono text-[10px] text-neutral-500 mt-2">NO_MCP_TOOL_DATA</p>
      </div>

      <div :if={@mcp_stats != []} class="space-y-4">
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
          <div class="bg-surface-container p-4 border-l-2 border-[#00eefc]/50">
            <div class="text-[9px] text-neutral-500 uppercase font-mono mb-1">TOTAL_CALLS</div>
            <div class="text-lg font-mono text-white">
              {Enum.reduce(@mcp_stats, 0, &(&1.calls + &2))}
            </div>
          </div>
          <div class="bg-surface-container p-4 border-l-2 border-[#00FF41]/50">
            <div class="text-[9px] text-neutral-500 uppercase font-mono mb-1">SUCCESS_RATE</div>
            <% total = Enum.reduce(@mcp_stats, 0, &(&1.calls + &2)) %>
            <% succeeded = Enum.reduce(@mcp_stats, 0, &(&1.succeeded + &2)) %>
            <div class="text-lg font-mono text-[#00FF41]">
              {if total > 0, do: "#{Float.round(succeeded / total * 100, 1)}%", else: "—"}
            </div>
          </div>
          <div class="bg-surface-container p-4 border-l-2 border-[#ff725e]/50">
            <div class="text-[9px] text-neutral-500 uppercase font-mono mb-1">FAILURES</div>
            <div class="text-lg font-mono text-[#ff725e]">
              {Enum.reduce(@mcp_stats, 0, &(&1.failed + &2))}
            </div>
          </div>
          <div class="bg-surface-container p-4 border-l-2 border-[#ffa44c]/50">
            <div class="text-[9px] text-neutral-500 uppercase font-mono mb-1">UNIQUE_TOOLS</div>
            <div class="text-lg font-mono text-[#ffa44c]">
              {length(@mcp_stats)}
            </div>
          </div>
        </div>

        <div class="bg-surface-container-low p-6 border-t-2 border-[#00eefc] hud-border">
          <h3 class="text-[#00eefc] font-mono text-xs tracking-widest uppercase mb-4">
            MCP_TOOL_RELIABILITY
          </h3>
          <div class="overflow-x-auto">
            <table class="w-full text-left font-mono text-[10px]">
              <thead class="border-b border-[#494847]/30 text-neutral-500">
                <tr>
                  <th class="py-2 font-medium">TOOL</th>
                  <th class="py-2 font-medium text-right">CALLS</th>
                  <th class="py-2 font-medium text-right">OK</th>
                  <th class="py-2 font-medium text-right">FAIL</th>
                  <th class="py-2 font-medium text-right">DENIED</th>
                  <th class="py-2 font-medium text-right">AVG_MS</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-[#494847]/10 text-white">
                <tr :for={stat <- @mcp_stats}>
                  <td class="py-3 text-[#00eefc]">{stat.tool}</td>
                  <td class="py-3 text-right">{stat.calls}</td>
                  <td class="py-3 text-right text-[#00FF41]">{stat.succeeded}</td>
                  <td class="py-3 text-right text-[#ff725e]">{stat.failed}</td>
                  <td class="py-3 text-right text-[#ffa44c]">{stat.denied}</td>
                  <td class="py-3 text-right text-neutral-400">
                    {if stat.avg_duration_ms >= 1, do: "#{stat.avg_duration_ms}ms", else: "<1ms"}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div class="bg-surface-container-low p-6 border-l border-[#494847]/20 hud-border">
          <h3 class="text-neutral-400 font-mono text-[10px] tracking-widest uppercase mb-4">
            RECENT_MCP_EVENTS
          </h3>
          <div class="overflow-x-auto max-h-[400px] overflow-y-auto">
            <table class="w-full text-left font-mono text-[10px]">
              <thead class="border-b border-[#494847]/30 text-neutral-500 sticky top-0 bg-surface-container-low">
                <tr>
                  <th class="py-2 font-medium">TIME</th>
                  <th class="py-2 font-medium">TOOL</th>
                  <th class="py-2 font-medium">STATUS</th>
                  <th class="py-2 font-medium text-right">DURATION</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-[#494847]/5">
                <tr :for={evt <- Enum.take(@mcp_events, 100)} class="hover:bg-[#00eefc]/5">
                  <td class="py-2 text-[#777575]">{format_time(evt.timestamp)}</td>
                  <td class="py-2 text-white">{evt.tool}</td>
                  <td class={"py-2 #{if(evt.status == "success", do: "text-[#00FF41]", else: if(evt.status == "denied", do: "text-[#ffa44c]", else: "text-[#ff725e]"))}"}>
                    {String.upcase(evt.status)}
                  </td>
                  <td class="py-2 text-right text-neutral-400">
                    {if evt.duration_ms > 0, do: "#{evt.duration_ms}ms", else: "<1ms"}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp detail_tabs do
    [
      {"timeline", "TIMELINE", "timeline"},
      {"tools", "TOOLS", "build"},
      {"costs", "COSTS", "payments"},
      {"events", "EVENTS", "list_alt"},
      {"files", "FILES", "description"},
      {"tasks", "TASKS", "task_alt"},
      {"agents", "AGENTS", "group"},
      {"mcp", "MCP_TOOLS", "api"}
    ]
  end

  # ---------------------------------------------------------------------------
  # Detail tab components
  # ---------------------------------------------------------------------------

  attr :phases, :list, required: true
  attr :total_duration_ms, :integer, default: 0

  defp phase_timeline(assigns) do
    timeline = build_phase_timeline(assigns.phases, assigns.total_duration_ms)
    assigns = assign(assigns, timeline: timeline)

    ~H"""
    <div :if={@timeline.phases == []} class="text-center py-12">
      <span class="material-symbols-outlined text-4xl text-[#494847]/30">timeline</span>
      <p class="text-[10px] font-mono text-neutral-500 mt-2">NO_PHASE_DATA_AVAILABLE</p>
    </div>
    <div :if={@timeline.phases != []} class="space-y-4">
      <div class="flex items-center justify-between text-[10px] font-mono text-[#777575]">
        <span>0s</span>
        <span class="font-bold text-white">
          TOTAL: {format_timeline_ms(@timeline.total_ms)}
        </span>
        <span>{format_timeline_ms(@timeline.total_ms)}</span>
      </div>

      <div class="bg-surface-container-low p-4 hud-border">
        <div class="relative h-12 overflow-hidden bg-black/40">
          <div
            :for={tick <- @timeline.ticks}
            class="absolute inset-y-0 border-l border-[#494847]/20"
            style={"left: #{tick.left_pct}%"}
          />
          <div
            :for={phase <- @timeline.phases}
            class={[
              "absolute top-1 bottom-1",
              hud_phase_bar_color(phase.status)
            ]}
            style={"left: #{phase.offset_pct}%; width: #{phase.width_pct}%"}
          >
            <div class="flex h-full items-center gap-2 px-3 text-[10px] font-mono font-bold text-black">
              <span :if={phase.width_pct >= 12} class="truncate uppercase">{phase.name}</span>
              <span :if={phase.width_pct >= 8} class="opacity-80">
                {format_timeline_ms(phase.computed_duration_ms)}
              </span>
            </div>
            <title>{timeline_hover_label(phase)}</title>
          </div>
        </div>

        <div class="relative mt-3 h-4">
          <span
            :for={tick <- @timeline.ticks}
            class="absolute -translate-x-1/2 text-[9px] font-mono text-[#777575]"
            style={"left: #{tick.left_pct}%"}
          >
            {tick.label}
          </span>
        </div>
      </div>

      <div
        :for={phase <- @timeline.phases}
        class="grid grid-cols-[minmax(0,12rem)_minmax(0,1fr)_auto] items-center gap-3"
      >
        <div class="min-w-0">
          <div class="truncate text-[11px] font-mono font-bold text-white uppercase">
            {phase.name}
          </div>
          <div class="font-mono text-[9px] text-[#777575]">
            +{format_timeline_ms(phase.offset_ms)} → +{format_timeline_ms(phase.end_ms)}
          </div>
        </div>
        <div class="relative h-6 overflow-hidden bg-black/40">
          <div
            :for={tick <- @timeline.ticks}
            class="absolute inset-y-0 border-l border-[#494847]/20"
            style={"left: #{tick.left_pct}%"}
          />
          <div
            class={[
              "absolute inset-y-0 text-[9px] font-mono text-black/80",
              hud_phase_bar_color(phase.status)
            ]}
            style={"left: #{phase.offset_pct}%; width: #{phase.width_pct}%"}
          >
            <div :if={phase.width_pct >= 7} class="flex h-full items-center truncate px-2 font-bold">
              {format_timeline_ms(phase.computed_duration_ms)}
            </div>
            <title>{timeline_hover_label(phase)}</title>
          </div>
        </div>
        <span class={[
          "px-2 py-0.5 text-[8px] font-mono font-bold border",
          case to_string(phase.status) do
            s when s in ["done", "completed"] ->
              "bg-[#00FF41]/10 text-[#00FF41] border-[#00FF41]/30"

            "failed" ->
              "bg-[#ff725e]/10 text-[#ff725e] border-[#ff725e]/30"

            s when s in ["running", "in_progress"] ->
              "bg-[#00eefc]/10 text-[#00eefc] border-[#00eefc]/30"

            _ ->
              "bg-[#494847]/10 text-[#777575] border-[#494847]/30"
          end
        ]}>
          {String.upcase(to_string(phase.status))}
        </span>
      </div>
    </div>
    """
  end

  attr :tools, :list, required: true

  defp tool_distribution(assigns) do
    max_count = assigns.tools |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 1 end)
    assigns = assign(assigns, :max_count, max_count)

    ~H"""
    <div :if={@tools == []} class="text-center py-12">
      <span class="material-symbols-outlined text-4xl text-[#494847]/30">construction</span>
      <p class="text-[10px] font-mono text-neutral-500 mt-2">NO_TOOL_USAGE_RECORDED</p>
    </div>
    <div :if={@tools != []} class="space-y-2">
      <div :for={{tool, count} <- @tools} class="flex items-center gap-3">
        <div class="w-28 text-[10px] font-mono truncate text-right text-[#777575]">{tool}</div>
        <div class="flex-1 h-4 bg-black/40">
          <div
            class="h-full bg-[#ffa44c] transition-all"
            style={"width: #{count / @max_count * 100}%"}
          />
        </div>
        <span class="text-[10px] font-mono w-10 text-right text-[#00eefc]">{count}</span>
      </div>
    </div>
    """
  end

  attr :costs, :list, required: true
  attr :agent_transcripts, :list, default: []

  defp cost_breakdown(assigns) do
    has_transcript_tokens =
      Enum.any?(assigns.agent_transcripts, fn t ->
        (t.tokens[:input] || 0) + (t.tokens[:output] || 0) > 0
      end)

    assigns = assign(assigns, has_transcript_tokens: has_transcript_tokens)

    ~H"""
    <%!-- Agent transcript token breakdown --%>
    <div :if={@has_transcript_tokens} class="bg-surface-container-low p-6 hud-border mb-4">
      <.hud_header icon="token" label="Token Usage [Session Transcripts]" class="mb-4" />
      <div class="overflow-x-auto">
        <table class="w-full text-left font-mono text-[11px]">
          <thead>
            <tr class="bg-black/40 text-[#777575] border-b border-[#494847]/10 uppercase tracking-widest">
              <th class="px-4 py-3 font-normal">AGENT</th>
              <th class="px-4 py-3 font-normal text-right">INPUT</th>
              <th class="px-4 py-3 font-normal text-right">OUTPUT</th>
              <th class="px-4 py-3 font-normal text-right">TOTAL</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-[#494847]/5">
            <tr :for={t <- @agent_transcripts} class="hover:bg-[#00eefc]/5 transition-colors">
              <td class="px-4 py-3 text-[#00eefc]">{t.agent_name}</td>
              <td class="px-4 py-3 text-right text-white">{format_tokens(t.tokens[:input] || 0)}</td>
              <td class="px-4 py-3 text-right text-white">{format_tokens(t.tokens[:output] || 0)}</td>
              <td class="px-4 py-3 text-right text-white font-bold">
                {format_tokens((t.tokens[:input] || 0) + (t.tokens[:output] || 0))}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>

    <%!-- Phase cost breakdown --%>
    <div :if={@costs == [] and not @has_transcript_tokens} class="text-center py-12">
      <span class="material-symbols-outlined text-4xl text-[#494847]/30">payments</span>
      <p class="text-[10px] font-mono text-neutral-500 mt-2">NO_COST_DATA_AVAILABLE</p>
    </div>
    <div :if={@costs != []} class="bg-surface-container-low p-6 hud-border">
      <.hud_header
        :if={@has_transcript_tokens}
        icon="receipt_long"
        label="Phase Cost Breakdown [Trace Events]"
        class="mb-4"
      />
      <div class="overflow-x-auto">
        <table class="w-full text-left font-mono text-[11px]">
          <thead>
            <tr class="bg-black/40 text-[#777575] border-b border-[#494847]/10 uppercase tracking-widest">
              <th class="px-4 py-3 font-normal">PHASE</th>
              <th class="px-4 py-3 font-normal text-right">INPUT</th>
              <th class="px-4 py-3 font-normal text-right">CACHE_READ</th>
              <th class="px-4 py-3 font-normal text-right">OUTPUT</th>
              <th class="px-4 py-3 font-normal text-right">COST</th>
              <th class="px-4 py-3 font-normal text-right">DURATION</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-[#494847]/5">
            <tr :for={c <- @costs} class="hover:bg-[#00eefc]/5 transition-colors">
              <td class="px-4 py-3 text-[#00eefc] uppercase">{c.phase_id}</td>
              <td class="px-4 py-3 text-right text-white">
                {format_tokens(c.input_tokens - Map.get(c, :cache_read_tokens, 0))}
              </td>
              <td class="px-4 py-3 text-right text-[#777575]">
                {format_tokens(Map.get(c, :cache_read_tokens, 0))}
              </td>
              <td class="px-4 py-3 text-right text-white">{format_tokens(c.output_tokens)}</td>
              <td class="px-4 py-3 text-right text-[#ffa44c] font-bold">
                ${Float.round(c.cost_usd * 1.0, 4)}
              </td>
              <td class="px-4 py-3 text-right text-[#777575]">{format_duration_ms(c.duration_ms)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :events, :list, required: true
  attr :filter, :string, required: true

  defp event_log(assigns) do
    filtered =
      if assigns.filter == "" do
        assigns.events
      else
        q = String.downcase(assigns.filter)

        Enum.filter(assigns.events, fn e ->
          String.contains?(String.downcase(e["eventType"] || ""), q) or
            String.contains?(String.downcase(e["tool"] || ""), q) or
            String.contains?(String.downcase(e["detail"] || ""), q)
        end)
      end

    assigns = assign(assigns, :filtered, Enum.take(filtered, -500))

    ~H"""
    <div class="mb-3">
      <div class="px-3 py-1 bg-black border border-[#494847]/20 flex items-center gap-2 max-w-xs">
        <span class="material-symbols-outlined text-xs text-[#777575]">search</span>
        <input
          type="text"
          placeholder="FILTER_BY_EVENT..."
          value={@filter}
          phx-change="filter_events"
          phx-debounce="300"
          name="q"
          class="bg-transparent border-none text-[10px] font-mono text-white focus:ring-0 w-full uppercase p-0"
        />
      </div>
    </div>

    <div :if={@filtered == []} class="text-center py-12">
      <span class="material-symbols-outlined text-4xl text-[#494847]/30">list_alt</span>
      <p class="text-[10px] font-mono text-neutral-500 mt-2">
        {if @filter != "", do: "NO_EVENTS_MATCH_FILTER", else: "NO_TRACE_EVENTS_RECORDED"}
      </p>
    </div>

    <div
      :if={@filtered != []}
      class="bg-surface-container-low hud-border max-h-[600px] overflow-y-auto"
    >
      <div class="space-y-0">
        <div
          :for={event <- @filtered}
          class="flex items-start gap-3 px-4 py-2 border-b border-[#494847]/5 hover:bg-[#00eefc]/5 transition-colors font-mono text-[11px]"
        >
          <span class="text-[#777575] w-16 shrink-0">
            {format_time(event["timestamp"])}
          </span>
          <span class={[
            "px-1.5 py-0.5 text-[8px] font-bold shrink-0",
            case event["eventType"] do
              "phase_start" ->
                "bg-[#00eefc]/10 text-[#00eefc] border border-[#00eefc]/30"

              "phase_end" ->
                "bg-[#00FF41]/10 text-[#00FF41] border border-[#00FF41]/30"

              t when t in ["verify_fail", "budget_exceeded", "loop_detected"] ->
                "bg-[#ff725e]/10 text-[#ff725e] border border-[#ff725e]/30"

              "verify_pass" ->
                "bg-[#00FF41]/10 text-[#00FF41] border border-[#00FF41]/30"

              _ ->
                "bg-[#494847]/10 text-[#777575] border border-[#494847]/30"
            end
          ]}>
            {event["eventType"]}
          </span>
          <span
            :if={event["tool"]}
            class="px-1.5 py-0.5 text-[8px] border border-[#494847]/30 text-[#777575] shrink-0"
          >
            {event["tool"]}
          </span>
          <span class="text-[#777575] truncate">
            {event["detail"] || ""}
          </span>
        </div>
      </div>
    </div>
    """
  end

  attr :files, :list, required: true

  defp files_view(assigns) do
    grouped = Enum.group_by(assigns.files, & &1.phase_id)
    assigns = assign(assigns, :grouped, grouped)

    ~H"""
    <div :if={@files == []} class="text-center py-12">
      <span class="material-symbols-outlined text-4xl text-[#494847]/30">description</span>
      <p class="text-[10px] font-mono text-neutral-500 mt-2">NO_FILE_CHANGES_TRACKED</p>
    </div>
    <div :if={@files != []} class="space-y-4">
      <div :for={{phase_id, files} <- @grouped} class="bg-surface-container-low p-4 hud-border">
        <h3 class="font-mono text-[11px] font-bold text-[#ffa44c] uppercase mb-3">{phase_id}</h3>
        <div class="space-y-1">
          <div :for={f <- files} class="flex items-center gap-2 text-[10px] font-mono">
            <span class={[
              "px-1.5 py-0.5 text-[8px] font-bold border",
              if(f.action == "created",
                do: "bg-[#00FF41]/10 text-[#00FF41] border-[#00FF41]/30",
                else: "bg-[#ffa44c]/10 text-[#ffa44c] border-[#ffa44c]/30"
              )
            ]}>
              {String.upcase(f.action)}
            </span>
            <span class="text-white truncate">{f.file}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Tasks tab component
  # ---------------------------------------------------------------------------

  attr :tasks, :list, required: true

  defp tasks_view(assigns) do
    ~H"""
    <div :if={@tasks == []} class="text-center py-12">
      <span class="material-symbols-outlined text-4xl text-[#494847]/30">assignment</span>
      <p class="text-[10px] font-mono text-neutral-500 mt-2">NO_TASK_EVENTS</p>
      <p class="text-[9px] font-mono text-neutral-600 mt-1">
        SDK SUBAGENT RUNS DO NOT USE TASKCREATE/TASKUPDATE
      </p>
    </div>
    <div :if={@tasks != []} class="bg-surface-container-low hud-border overflow-hidden">
      <div class="overflow-x-auto">
        <table class="w-full text-left font-mono text-[11px]">
          <thead>
            <tr class="bg-black/40 text-[#777575] border-b border-[#494847]/10 uppercase tracking-widest">
              <th class="px-4 py-3 font-normal">TIMESTAMP</th>
              <th class="px-4 py-3 font-normal">ACTION</th>
              <th class="px-4 py-3 font-normal">DETAIL</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-[#494847]/5">
            <tr :for={task <- @tasks} class="hover:bg-[#00eefc]/5 transition-colors">
              <td class="px-4 py-3 text-[#777575]">{format_time(task.timestamp)}</td>
              <td class="px-4 py-3">
                <span class={[
                  "px-1.5 py-0.5 text-[8px] font-bold border",
                  case task.tool do
                    "TaskCreate" -> "bg-[#00FF41]/10 text-[#00FF41] border-[#00FF41]/30"
                    "TaskUpdate" -> "bg-[#00eefc]/10 text-[#00eefc] border-[#00eefc]/30"
                    _ -> "bg-[#494847]/10 text-[#777575] border-[#494847]/30"
                  end
                ]}>
                  {task.tool}
                </span>
              </td>
              <td class="px-4 py-3 text-white max-w-lg truncate">{task.detail}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Agents tab components
  # ---------------------------------------------------------------------------

  attr :run_id, :string, required: true
  attr :run_summary, :map, default: nil
  attr :lifecycle_agents, :list, required: true
  attr :phase_events, :map, required: true
  attr :session_logs, :map, required: true
  attr :expanded_logs, :any, required: true
  attr :agent_transcripts, :list, required: true

  defp agents_view(assigns) do
    phase_agents = (assigns.run_summary && assigns.run_summary[:agent_details]) || []
    phases = (assigns.run_summary && assigns.run_summary[:phases]) || []
    lifecycle = assigns.lifecycle_agents
    spawn_count = (assigns.run_summary && assigns.run_summary[:agent_spawn_count]) || 0
    transcripts = assigns.agent_transcripts

    all_names =
      (Enum.map(lifecycle, & &1.name) ++
         Enum.map(phase_agents, & &1.name) ++
         Enum.map(transcripts, & &1.agent_name))
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()

    # Build per-agent tool call count from transcripts
    transcript_map = Map.new(transcripts, fn t -> {t.agent_name, t} end)

    assigns =
      assign(assigns,
        all_agent_names: all_names,
        phase_agents: phase_agents,
        phases: phases,
        lifecycle: lifecycle,
        spawn_count: spawn_count,
        transcripts: transcripts,
        transcript_map: transcript_map
      )

    ~H"""
    <div
      :if={@all_agent_names == [] and @spawn_count == 0}
      class="text-center py-12"
    >
      <span class="material-symbols-outlined text-4xl text-[#494847]/30">group</span>
      <p class="text-[10px] font-mono text-neutral-500 mt-2">NO_AGENT_DATA_AVAILABLE</p>
    </div>

    <div :if={@all_agent_names != [] or @spawn_count > 0} class="space-y-4">
      <.hud_header
        icon="smart_toy"
        label={"Agents (#{max(length(@all_agent_names), @spawn_count)})"}
        class="mb-4"
      />
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
        <div
          :for={name <- @all_agent_names}
          class="bg-surface-container-low p-4 hud-border border-l-2 border-[#ffa44c]/30"
        >
          <div class="flex items-center gap-2">
            <span class="material-symbols-outlined text-[#ffa44c]">smart_toy</span>
            <span class="font-mono text-[11px] font-bold text-white">{name}</span>
          </div>
          <div
            :if={Map.has_key?(@transcript_map, name)}
            class="text-[10px] text-[#00eefc] font-mono mt-1"
          >
            {length(@transcript_map[name].tool_calls)} TOOL_CALLS
          </div>
          <div
            :for={lc <- Enum.filter(@lifecycle, &(&1.name == name))}
            class="text-[10px] text-[#777575] font-mono mt-1 flex gap-1 flex-wrap"
          >
            <span
              :for={ev <- Enum.take(lc.events, 5)}
              class="px-1 py-0.5 bg-[#494847]/10 border border-[#494847]/30 text-[8px]"
            >
              {ev.event}
            </span>
          </div>
        </div>
      </div>
      <div
        :if={@spawn_count > length(@all_agent_names)}
        class="text-[10px] font-mono text-[#494847] italic"
      >
        + {@spawn_count - length(@all_agent_names)} AGENT(S) SPAWNED (NAMES NOT CAPTURED)
      </div>
    </div>

    <%!-- Per-agent tool call timelines --%>
    <div :if={@transcripts != []} class="space-y-3 mt-6">
      <.hud_header icon="timeline" label="Agent Activity" class="mb-4" />
      <.agent_transcript_section
        :for={transcript <- @transcripts}
        transcript={transcript}
        expanded_logs={@expanded_logs}
      />
    </div>
    """
  end

  attr :transcript, :map, required: true
  attr :expanded_logs, :any, required: true

  defp agent_transcript_section(assigns) do
    agent_key = "transcript-#{assigns.transcript.agent_name}"
    is_expanded = MapSet.member?(assigns.expanded_logs, agent_key)
    tool_calls = assigns.transcript.tool_calls
    files_created = assigns.transcript[:files_created] || []
    files_modified = assigns.transcript[:files_modified] || []

    assigns =
      assign(assigns,
        agent_key: agent_key,
        is_expanded: is_expanded,
        tool_calls: tool_calls,
        tool_count: length(tool_calls),
        files_created: files_created,
        files_modified: files_modified
      )

    ~H"""
    <div class="bg-surface-container-low hud-border">
      <button
        class="w-full p-4 flex items-center justify-between text-left hover:bg-surface-container transition-colors"
        phx-click="toggle_session_log"
        phx-value-phase={@agent_key}
      >
        <div class="flex items-center gap-2 flex-wrap">
          <span class="material-symbols-outlined text-sm text-[#777575]">
            {if @is_expanded, do: "expand_more", else: "chevron_right"}
          </span>
          <span class="material-symbols-outlined text-sm text-[#ffa44c]">smart_toy</span>
          <span class="font-mono text-[11px] font-bold text-white">{@transcript.agent_name}</span>
          <span class="px-1.5 py-0.5 text-[8px] font-mono bg-[#494847]/10 border border-[#494847]/30 text-[#777575]">
            {@tool_count} TOOLS
          </span>
          <span
            :if={@files_created != []}
            class="px-1.5 py-0.5 text-[8px] font-mono bg-[#00FF41]/10 text-[#00FF41] border border-[#00FF41]/30"
          >
            {length(@files_created)} CREATED
          </span>
          <span
            :if={@files_modified != []}
            class="px-1.5 py-0.5 text-[8px] font-mono bg-[#ffa44c]/10 text-[#ffa44c] border border-[#ffa44c]/30"
          >
            {length(@files_modified)} MODIFIED
          </span>
        </div>
      </button>

      <div :if={@is_expanded} class="px-4 pb-4 border-t border-[#494847]/10">
        <div :if={@files_created != [] or @files_modified != []} class="mb-3 mt-3 space-y-1">
          <div :for={f <- @files_created} class="flex items-center gap-2 text-[10px] font-mono">
            <span class="px-1 py-0.5 text-[8px] bg-[#00FF41]/10 text-[#00FF41] border border-[#00FF41]/30">
              CREATED
            </span>
            <span class="text-white truncate">{f}</span>
          </div>
          <div :for={f <- @files_modified} class="flex items-center gap-2 text-[10px] font-mono">
            <span class="px-1 py-0.5 text-[8px] bg-[#ffa44c]/10 text-[#ffa44c] border border-[#ffa44c]/30">
              MODIFIED
            </span>
            <span class="text-white truncate">{f}</span>
          </div>
        </div>

        <div :if={@tool_calls == []} class="text-[10px] font-mono text-[#494847] italic py-4">
          NO_TOOL_CALLS_IN_TRANSCRIPT
        </div>
        <div :if={@tool_calls != []} class="max-h-96 overflow-y-auto mt-3">
          <div
            :for={tc <- @tool_calls}
            class="flex items-start gap-2 px-2 py-1.5 border-b border-[#494847]/5 hover:bg-[#00eefc]/5 transition-colors font-mono text-[10px]"
          >
            <span class="text-[#777575] w-16 shrink-0">{format_time(tc.timestamp)}</span>
            <span class={[
              "px-1 py-0.5 text-[8px] font-bold border shrink-0",
              case tc.tool do
                "Read" -> "bg-[#00eefc]/10 text-[#00eefc] border-[#00eefc]/30"
                t when t in ["Edit", "Write"] -> "bg-[#00FF41]/10 text-[#00FF41] border-[#00FF41]/30"
                "Bash" -> "bg-[#ffa44c]/10 text-[#ffa44c] border-[#ffa44c]/30"
                "Agent" -> "bg-[#ff725e]/10 text-[#ff725e] border-[#ff725e]/30"
                _ -> "bg-[#494847]/10 text-[#777575] border-[#494847]/30"
              end
            ]}>
              {tc.tool}
            </span>
            <span class="text-[#777575] truncate">{tc.detail}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helper components
  # ---------------------------------------------------------------------------

  defp sort_indicator(field, current, dir) do
    if field == current do
      if dir == "desc", do: raw("&darr;"), else: raw("&uarr;")
    else
      ""
    end
  end

  defp hud_phase_bar_color("done"), do: "bg-[#ffa44c]"
  defp hud_phase_bar_color("completed"), do: "bg-[#ffa44c]"
  defp hud_phase_bar_color("running"), do: "bg-[#00eefc]"
  defp hud_phase_bar_color("in_progress"), do: "bg-[#00eefc]"
  defp hud_phase_bar_color("failed"), do: "bg-[#ff725e]"
  defp hud_phase_bar_color(_), do: "bg-[#494847]"

  defp phase_duration_ms(phase) do
    with start when is_binary(start) <- phase.started_at,
         stop when is_binary(stop) <- phase.ended_at,
         {:ok, d1, _} <- DateTime.from_iso8601(start),
         {:ok, d2, _} <- DateTime.from_iso8601(stop) do
      max(DateTime.diff(d2, d1, :millisecond), 1)
    else
      _ -> 1
    end
  end

  defp build_phase_timeline(phases, total_duration_ms) do
    prepared =
      phases
      |> Enum.map(fn phase ->
        duration_ms = phase_duration_ms(phase)
        started_at_ms = phase_timestamp_ms(phase.started_at)

        ended_at_ms =
          phase_timestamp_ms(phase.ended_at) || inferred_phase_end_ms(started_at_ms, duration_ms)

        phase
        |> Map.put(:computed_duration_ms, duration_ms)
        |> Map.put(:started_at_ms, started_at_ms)
        |> Map.put(:ended_at_ms, ended_at_ms)
      end)

    min_started_at_ms =
      prepared
      |> Enum.map(& &1.started_at_ms)
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> nil end)

    {positioned, fallback_cursor_ms} =
      Enum.map_reduce(prepared, 0, fn phase, cursor_ms ->
        offset_ms =
          case {min_started_at_ms, phase.started_at_ms} do
            {min_ms, start_ms} when is_integer(min_ms) and is_integer(start_ms) ->
              max(start_ms - min_ms, 0)

            _ ->
              cursor_ms
          end

        end_ms =
          case {min_started_at_ms, phase.ended_at_ms} do
            {min_ms, end_at_ms} when is_integer(min_ms) and is_integer(end_at_ms) ->
              max(end_at_ms - min_ms, offset_ms + phase.computed_duration_ms)

            _ ->
              offset_ms + phase.computed_duration_ms
          end

        positioned_phase =
          phase
          |> Map.put(:offset_ms, offset_ms)
          |> Map.put(:end_ms, end_ms)

        {positioned_phase, max(cursor_ms, end_ms)}
      end)

    total_ms = Enum.max([normalize_total_duration(total_duration_ms), fallback_cursor_ms, 1])

    %{
      phases:
        Enum.map(positioned, fn phase ->
          phase
          |> Map.put(:offset_pct, phase_offset_pct(phase.offset_ms, total_ms))
          |> Map.put(:width_pct, phase_width_pct(phase.computed_duration_ms, total_ms))
        end),
      total_ms: total_ms,
      ticks: timeline_ticks(total_ms)
    }
  end

  defp phase_timestamp_ms(nil), do: nil

  defp phase_timestamp_ms(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp inferred_phase_end_ms(started_at_ms, duration_ms)
       when is_integer(started_at_ms) and is_number(duration_ms) do
    started_at_ms + max(duration_ms, 1)
  end

  defp inferred_phase_end_ms(_, _), do: nil

  defp normalize_total_duration(ms) when is_number(ms), do: max(trunc(ms), 0)
  defp normalize_total_duration(_), do: 0

  defp phase_offset_pct(_offset, total) when total <= 0, do: 0
  defp phase_offset_pct(offset, total), do: Float.round(offset / total * 100, 2)

  defp phase_width_pct(_duration, total) when total <= 0, do: 0
  defp phase_width_pct(duration, total), do: max(Float.round(duration / total * 100, 2), 0.8)

  defp timeline_ticks(total_ms) do
    Enum.map(0..5, fn index ->
      left_pct = Float.round(index / 5 * 100, 2)
      tick_ms = round(total_ms / 5 * index)
      %{left_pct: left_pct, label: format_timeline_ms(tick_ms)}
    end)
  end

  defp format_timeline_ms(ms) when is_number(ms) and ms <= 0, do: "0s"
  defp format_timeline_ms(ms), do: format_duration_ms(ms)

  defp timeline_hover_label(phase) do
    [
      phase.name,
      "start +#{format_timeline_ms(phase.offset_ms)}",
      "#{format_timeline_ms(phase.computed_duration_ms)}",
      phase.status
    ]
    |> Enum.join(" · ")
  end

  # Compute total tokens from agent transcripts (primary) with fallback to run_summary trace data
  defp compute_total_tokens(nil, _transcripts), do: %{input: 0, output: 0}

  defp compute_total_tokens(run_summary, transcripts)
       when is_list(transcripts) and transcripts != [] do
    input = Enum.reduce(transcripts, 0, fn t, acc -> acc + (t.tokens[:input] || 0) end)
    output = Enum.reduce(transcripts, 0, fn t, acc -> acc + (t.tokens[:output] || 0) end)

    if input + output > 0 do
      %{input: input, output: output}
    else
      %{
        input: run_summary[:total_input_tokens] || 0,
        output: run_summary[:total_output_tokens] || 0
      }
    end
  end

  defp compute_total_tokens(run_summary, _transcripts) do
    %{
      input: run_summary[:total_input_tokens] || 0,
      output: run_summary[:total_output_tokens] || 0
    }
  end

  # Format a workflow name slug to a title (e.g. "coding-sprint" -> "Coding Sprint")
  defp format_phase_name_label(name) when is_binary(name) do
    name
    |> String.replace(~r/[-_]/, " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_phase_name_label(_), do: "Trace"

  # Tool-specific colors matching the TS dashboard's TOOL_COLORS
  defp traces_index_path(window, client_filter, workspace_filter) do
    query =
      %{}
      |> put_query("window", window != "7d", window)
      |> ScopeFilters.apply_scope_query(client_filter, workspace_filter)

    "/traces" <> encode_query(query)
  end

  defp trace_detail_path(run_id, window, client_filter, workspace_filter) do
    query =
      %{}
      |> put_query("window", window != "7d", window)
      |> ScopeFilters.apply_scope_query(client_filter, workspace_filter)

    "/traces/#{run_id}" <> encode_query(query)
  end

  defp trace_compare_path(left_run_id, right_run_id, window, client_filter, workspace_filter) do
    query =
      %{}
      |> put_query("window", window != "7d", window)
      |> ScopeFilters.apply_scope_query(client_filter, workspace_filter)

    "/traces/compare/#{left_run_id}/#{right_run_id}" <> encode_query(query)
  end

  defp build_trace_compare(left_run_id, left_summary, right_run_id, right_summary) do
    left_costs = phase_cost_index(left_summary)
    right_costs = phase_cost_index(right_summary)
    left_phases = phase_index(left_summary)
    right_phases = phase_index(right_summary)

    phase_ids =
      (Map.keys(left_costs) ++
         Map.keys(right_costs) ++ Map.keys(left_phases) ++ Map.keys(right_phases))
      |> Enum.uniq()

    rows =
      phase_ids
      |> Enum.map(fn phase_id ->
        left_phase = Map.get(left_phases, phase_id, %{})
        right_phase = Map.get(right_phases, phase_id, %{})
        left_cost = Map.get(left_costs, phase_id, %{})
        right_cost = Map.get(right_costs, phase_id, %{})

        left_duration_ms = choose_duration(left_cost, left_phase)
        right_duration_ms = choose_duration(right_cost, right_phase)

        left_tokens =
          int(Map.get(left_cost, :input_tokens, 0)) + int(Map.get(left_cost, :output_tokens, 0))

        right_tokens =
          int(Map.get(right_cost, :input_tokens, 0)) + int(Map.get(right_cost, :output_tokens, 0))

        left_cost_usd = float(Map.get(left_cost, :cost_usd, 0.0))
        right_cost_usd = float(Map.get(right_cost, :cost_usd, 0.0))

        %{
          phase_id: phase_id,
          phase_name: Map.get(left_phase, :name) || Map.get(right_phase, :name) || phase_id,
          left_duration_ms: left_duration_ms,
          right_duration_ms: right_duration_ms,
          duration_delta_ms: left_duration_ms - right_duration_ms,
          left_tokens: left_tokens,
          right_tokens: right_tokens,
          tokens_delta: left_tokens - right_tokens,
          left_cost_usd: left_cost_usd,
          right_cost_usd: right_cost_usd,
          cost_delta: left_cost_usd - right_cost_usd
        }
      end)
      |> Enum.sort_by(& &1.phase_name)

    totals = %{
      duration_delta_ms: Enum.reduce(rows, 0, &(&1.duration_delta_ms + &2)),
      tokens_delta: Enum.reduce(rows, 0, &(&1.tokens_delta + &2)),
      cost_delta: Enum.reduce(rows, 0.0, &(&1.cost_delta + &2))
    }

    %{
      left_run_id: left_run_id,
      right_run_id: right_run_id,
      rows: rows,
      totals: totals
    }
  end

  defp phase_cost_index(nil), do: %{}

  defp phase_cost_index(summary) when is_map(summary) do
    summary
    |> Map.get(:costs, [])
    |> Map.new(fn cost -> {Map.get(cost, :phase_id), cost} end)
  end

  defp phase_index(nil), do: %{}

  defp phase_index(summary) when is_map(summary) do
    summary
    |> Map.get(:phases, [])
    |> Map.new(fn phase ->
      {Map.get(phase, :id) || Map.get(phase, :phase_id), phase}
    end)
  end

  defp choose_duration(cost, phase) do
    duration = int(Map.get(cost, :duration_ms, 0))

    cond do
      duration > 0 ->
        duration

      true ->
        phase_duration_ms(phase)
    end
  end

  defp int(value) when is_integer(value), do: value
  defp int(value) when is_float(value), do: round(value)
  defp int(_), do: 0

  defp float(value) when is_float(value), do: value
  defp float(value) when is_integer(value), do: value * 1.0
  defp float(_), do: 0.0

  defp split_signals(summary) when is_binary(summary) do
    summary
    |> String.split(";", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp split_signals(_), do: []

  defp hud_delta_class(delta) when is_number(delta) and delta > 0, do: "text-[#ff725e]"
  defp hud_delta_class(delta) when is_number(delta) and delta < 0, do: "text-[#00FF41]"
  defp hud_delta_class(_), do: "text-white"

  defp format_signed_duration(delta_ms) when is_number(delta_ms) do
    prefix = if delta_ms > 0, do: "+", else: ""
    prefix <> format_duration_ms(abs(round(delta_ms)))
  end

  defp format_signed_duration(_), do: "0s"

  defp format_signed_tokens(delta) when is_number(delta) do
    prefix = if delta > 0, do: "+", else: ""
    prefix <> format_tokens(abs(round(delta)))
  end

  defp format_signed_tokens(_), do: "0"

  defp format_signed_cost(delta) when is_number(delta) do
    prefix = if delta > 0, do: "+", else: ""
    prefix <> "$" <> :erlang.float_to_binary(abs(delta), decimals: 4)
  end

  defp format_signed_cost(_), do: "$0.0000"

  defp build_regression_panel(runs) do
    by_workflow = Enum.group_by(runs, &(&1.workflow_name || "unknown"))

    analyses =
      by_workflow
      |> Enum.map(fn {workflow, wf_runs} ->
        sorted = Enum.sort_by(wf_runs, &(&1.started_at || ""), :desc)
        recent = Enum.take(sorted, 3)
        previous = sorted |> Enum.drop(3) |> Enum.take(3)
        latest = Enum.at(sorted, 0)
        baseline = Enum.at(sorted, 3) || Enum.at(sorted, 1)
        signals = regression_signals(recent, previous)
        action = action_for_signals(signals)

        %{
          workflow: workflow,
          signals: signals,
          summary: Enum.join(signals, "; "),
          action: action,
          score: length(signals),
          latest_run_id: latest && latest.run_id,
          baseline_run_id: baseline && baseline.run_id,
          workspace: run_workspace(latest || baseline || %{})
        }
      end)
      |> Enum.sort_by(&{-&1.score, &1.workflow})

    %{
      total_workflows: map_size(by_workflow),
      regressed:
        analyses
        |> Enum.filter(&(&1.signals != []))
        |> Enum.take(5),
      actionable:
        analyses
        |> Enum.filter(&(not is_nil(&1.action)))
        |> Enum.take(5)
    }
  end

  defp regression_signals([], _), do: []
  defp regression_signals(_, []), do: []

  defp regression_signals(recent, previous) do
    r = run_window_metrics(recent)
    p = run_window_metrics(previous)

    []
    |> maybe_add_signal(
      p.success_rate - r.success_rate > 0.15,
      "Success rate dropped #{pct(p.success_rate - r.success_rate)}"
    )
    |> maybe_add_signal(
      ratio_up?(r.avg_duration_ms, p.avg_duration_ms, 0.2),
      "Average duration up #{ratio_delta(r.avg_duration_ms, p.avg_duration_ms)}"
    )
    |> maybe_add_signal(
      ratio_up?(r.avg_tokens, p.avg_tokens, 0.25),
      "Token spend up #{ratio_delta(r.avg_tokens, p.avg_tokens)}"
    )
    |> maybe_add_signal(
      ratio_up?(r.avg_cost, p.avg_cost, 0.25),
      "Cost up #{ratio_delta(r.avg_cost, p.avg_cost)}"
    )
  end

  defp run_window_metrics(runs) do
    total = max(length(runs), 1)

    %{
      success_rate:
        Enum.count(runs, fn run -> (run.status || "") in ["done", "completed"] end) / total,
      avg_duration_ms: Enum.reduce(runs, 0, &(&2 + (run_number(&1.duration_ms) || 0))) / total,
      avg_tokens: Enum.reduce(runs, 0, &(&2 + (run_number(&1.total_tokens) || 0))) / total,
      avg_cost: Enum.reduce(runs, 0.0, &(&2 + (run_number(&1.total_cost_usd) || 0.0))) / total
    }
  end

  defp run_number(value) when is_integer(value) or is_float(value), do: value
  defp run_number(_), do: 0

  defp ratio_up?(_recent, previous, _threshold) when previous <= 0, do: false
  defp ratio_up?(recent, previous, threshold), do: (recent - previous) / previous > threshold

  defp ratio_delta(_recent, previous) when previous <= 0, do: "0%"

  defp ratio_delta(recent, previous) do
    delta = max(recent - previous, 0.0)
    pct(delta / previous)
  end

  defp pct(value) when is_number(value), do: "#{Float.round(value * 100, 0)}%"
  defp pct(_), do: "0%"

  defp maybe_add_signal(signals, true, message), do: signals ++ [message]
  defp maybe_add_signal(signals, false, _message), do: signals

  defp action_for_signals([]), do: nil

  defp action_for_signals(signals) do
    cond do
      Enum.any?(signals, &String.contains?(&1, "Success rate dropped")) ->
        "Prioritize failure triage: inspect failed runs, isolate phase regressions, and add a guardrail test."

      Enum.any?(signals, &String.contains?(&1, "Token spend up")) or
          Enum.any?(signals, &String.contains?(&1, "Cost up")) ->
        "Run an efficiency pass: tighten prompts/tools for the slowest phase and re-benchmark token/cost deltas."

      Enum.any?(signals, &String.contains?(&1, "Average duration up")) ->
        "Profile the longest phase transition and reduce serial waits by parallelizing or trimming blockers."

      true ->
        "Review latest runs against prior baseline and convert the largest regression into a concrete remediation card."
    end
  end

  defp put_query(query, _key, false, _value), do: query
  defp put_query(query, key, true, value), do: Map.put(query, key, value)

  defp encode_query(query) when map_size(query) == 0, do: ""
  defp encode_query(query), do: "?" <> URI.encode_query(query)

  defp source_label(:postgres), do: "Postgres"
  defp source_label(:filesystem), do: "Filesystem"
  defp source_label(:jsonl), do: "JSONL"
  defp source_label(:empty), do: "Empty"
  defp source_label(_), do: "Unknown"

  defp run_workspace(run) when is_map(run) do
    Map.get(run, :workspace_path)
  end
end
