defmodule CrucibleWeb.BudgetLive do
  @moduledoc """
  LiveView for the budget analytics dashboard.

  Displays real-time spend tracking with breakdowns by model, session, agent,
  and task. Supports scope filtering by client and workspace, configurable time
  ranges, and CSV/JSON export of cost events. Auto-refreshes via a periodic
  timer and PubSub subscription to `budget:updates`.
  """

  use CrucibleWeb, :live_view

  require Logger

  alias Crucible.{BudgetTracker, CostEventReader, TraceReader}
  alias Crucible.Utils.Range, as: RangeUtils
  alias CrucibleWeb.BudgetLive.Helpers, as: BudgetHelpers
  alias CrucibleWeb.Live.{RefreshTimer, ScopeFilters}

  @refresh_interval 5_000

  @doc """
  Mounts the budget LiveView.

  Subscribes to `budget:updates` PubSub topic and starts a periodic refresh
  timer when the socket is connected. Initializes default assigns for scope
  filters, event limit, and budget days, then loads all dashboard data.
  """
  @impl true
  def mount(_params, _session, socket) do
    timer =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Crucible.PubSub, "budget:updates")
        RefreshTimer.start(@refresh_interval)
      end

    {:ok,
     assign(socket,
       page_title: "Budget",
       refresh_timer: timer,
       current_path: "/budget",
       client_filter: ScopeFilters.all_scope(),
       workspace_filter: ScopeFilters.all_scope(),
       client_options: ScopeFilters.client_options([]),
       workspace_options: ScopeFilters.workspace_options([]),
       event_limit: 50,
       budget_days: 1,
       loading: !connected?(socket),
       data_stale: [],
       last_updated_at: DateTime.utc_now()
     )
     |> load_data()}
  end

  @doc """
  Cancels the refresh timer when the LiveView process terminates.
  """
  @impl true
  def terminate(_reason, socket) do
    RefreshTimer.cancel(socket.assigns[:refresh_timer])
  end

  @doc """
  Applies client and workspace scope filters from URL query parameters and reloads data.
  """
  @impl true
  def handle_params(params, _uri, socket) do
    client_filter = ScopeFilters.normalize_param(params["client_id"])
    workspace_filter = ScopeFilters.normalize_param(params["workspace"])

    {:noreply,
     socket
     |> assign(
       client_filter: client_filter,
       workspace_filter: workspace_filter,
       current_path: BudgetHelpers.budget_path(client_filter, workspace_filter)
     )
     |> load_data()}
  end

  @doc """
  Handles periodic refresh ticks and PubSub budget update messages.

  The `:refresh` clause fires on the timer interval, reloading data and advancing
  the timer. The `{:budget_update, _}` clause fires on PubSub broadcasts, resetting
  the timer to avoid redundant refreshes.
  """
  @impl true
  def handle_info(:refresh, socket) do
    socket = load_data(socket)
    timer = RefreshTimer.tick(socket.assigns[:refresh_timer], true)
    {:noreply, assign(socket, refresh_timer: timer, last_updated_at: DateTime.utc_now())}
  end

  def handle_info({:budget_update, _}, socket) do
    timer = RefreshTimer.reset(socket.assigns[:refresh_timer])
    {:noreply, assign(load_data(socket), refresh_timer: timer, last_updated_at: DateTime.utc_now())}
  end

  @doc """
  Handles user interaction events from the dashboard UI.

  Supported events:
    - `"set_event_limit"` — changes the number of cost events displayed in the log
    - `"set_budget_days"` — changes the time range for rollup breakdowns
    - `"set_scope_filters"` — updates client/workspace filters via URL patch
    - `"export_events"` — triggers a client-side download of events as CSV or JSON
  """
  @impl true
  def handle_event("set_event_limit", %{"limit" => limit}, socket) do
    {limit, _} = Integer.parse(limit)
    {:noreply, assign(socket, event_limit: limit) |> load_data()}
  end

  def handle_event("set_budget_days", %{"days" => days_str}, socket) do
    days = String.to_integer(days_str)
    {:noreply, assign(socket, budget_days: days) |> load_data()}
  end

  def handle_event("set_scope_filters", params, socket) do
    client_filter = ScopeFilters.normalize_param(params["client_id"])
    workspace_filter = ScopeFilters.normalize_param(params["workspace"])
    {:noreply, push_patch(socket, to: BudgetHelpers.budget_path(client_filter, workspace_filter))}
  end

  def handle_event("export_events", %{"format" => format}, socket) do
    events = socket.assigns.events

    {content, filename, content_type} =
      case format do
        "csv" -> BudgetHelpers.events_to_csv(events)
        _ -> BudgetHelpers.events_to_json(events)
      end

    {:noreply,
     push_event(socket, "download", %{
       content: content,
       filename: filename,
       content_type: content_type
     })}
  end

  defp load_data(socket) do
    client_filter = socket.assigns[:client_filter] || ScopeFilters.all_scope()
    workspace_filter = socket.assigns[:workspace_filter] || ScopeFilters.all_scope()
    client_id = ScopeFilters.query_value(client_filter)
    workspace = ScopeFilters.query_value(workspace_filter)

    status =
      safe_call(fn -> BudgetTracker.status() end, %{
        daily_spent: 0.0,
        daily_limit: 100.0,
        daily_remaining: 100.0,
        is_over_budget: false
      })

    limit = socket.assigns.event_limit
    events = load_scoped_events(limit, client_id, workspace)

    model_breakdown = BudgetHelpers.model_breakdown(events)
    raw_pct = BudgetHelpers.spend_percentage(status.daily_spent, status.daily_limit)
    spend_pct = RangeUtils.clamp(raw_pct, 0.0, 999.9)

    days = socket.assigns[:budget_days] || 1
    since = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)
    scope_opts = [since: since, client_id: client_id, workspace: workspace]

    # Parallelize independent data fetches
    tasks = %{
      runs: Task.async(fn -> safe_call(fn -> TraceReader.list_runs() end, []) end),
      sessions:
        Task.async(fn ->
          safe_call(fn -> CostEventReader.session_rollups(scope_opts) end, [])
        end),
      agents:
        Task.async(fn ->
          safe_call(fn -> CostEventReader.agent_rollups(scope_opts) end, [])
        end),
      tasks_bd:
        Task.async(fn ->
          safe_call(fn -> CostEventReader.task_rollups(scope_opts) end, [])
        end)
    }

    {results, timed_out} =
      Enum.reduce(tasks, {%{}, []}, fn {k, task}, {acc, stale} ->
        try do
          {Map.put(acc, k, Task.await(task, 5_000)), stale}
        catch
          :exit, _ ->
            Task.shutdown(task, :brutal_kill)
            Logger.warning("[BudgetLive] Task.await timeout for #{k}, returning empty fallback")
            {Map.put(acc, k, []), [k | stale]}
        end
      end)

    runs = results.runs

    client_options =
      runs
      |> Enum.map(&Map.get(&1, :client_id))
      |> ScopeFilters.client_options()

    workspace_options =
      runs
      |> Enum.map(&Map.get(&1, :workspace_path))
      |> ScopeFilters.workspace_options()

    sessions_breakdown = results.sessions
    agents_breakdown = results.agents
    tasks_breakdown = results.tasks_bd

    assign(socket,
      status: status,
      events: events,
      model_breakdown: model_breakdown,
      sessions_breakdown: sessions_breakdown,
      agents_breakdown: agents_breakdown,
      tasks_breakdown: tasks_breakdown,
      client_options: client_options,
      workspace_options: workspace_options,
      spend_pct: spend_pct,
      loading: false,
      data_stale: timed_out
    )
  end

  @doc """
  Renders the budget analytics dashboard.

  Displays a budget gauge with daily spend/limit, alert banners when over budget,
  model spend breakdown bars, agent/session/task rollup tables, a scrollable cost
  event log with export controls, and a telemetry footer with summary counts.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <%!-- Page header --%>
        <div class="flex flex-col md:flex-row md:items-end justify-between gap-4 mb-2">
          <div>
            <div class="flex items-center gap-2 mb-1">
              <span class="w-2 h-2 bg-[#00eefc] animate-pulse" />
              <span class="text-[#00eefc] font-mono text-[10px] tracking-[0.3em] uppercase">
                SYSTEM MONITORING / BUDGET
              </span>
            </div>
            <h1 class="text-3xl md:text-4xl font-headline font-bold text-white tracking-tighter uppercase">
              BUDGET_ANALYTICS
            </h1>
          </div>
          <.scope_filter_bar
            event="set_scope_filters"
            client_filter={@client_filter}
            workspace_filter={@workspace_filter}
            client_options={@client_options}
            workspace_options={@workspace_options}
          />
        </div>
        <div class="mb-4 flex justify-end">
          <.last_updated at={@last_updated_at} />
        </div>

        <%!-- Loading skeleton --%>
        <div :if={@loading} class="space-y-6">
          <div class="bg-surface-container-low hud-border p-6 animate-pulse">
            <div class="h-48 bg-surface-container-high" />
          </div>
        </div>

        <%!-- Stale data warning --%>
        <div :if={@data_stale != []} class="bg-[#ffa44c]/10 border border-[#ffa44c]/30 p-4 flex items-center gap-3">
          <span class="material-symbols-outlined text-[#ffa44c]">warning</span>
          <div>
            <div class="text-[#ffa44c] font-mono text-[10px] font-bold tracking-widest uppercase">DATA_INCOMPLETE</div>
            <div class="text-neutral-400 text-[10px] font-mono">
              Some data sources timed out ({Enum.map_join(@data_stale, ", ", &to_string/1)}). Displayed values may be stale.
            </div>
          </div>
        </div>

        <div :if={!@loading} class="grid grid-cols-1 md:grid-cols-12 gap-6">
          <%!-- Left Column: Gauge & Alerts --%>
          <div class="md:col-span-4 space-y-6">
            <%!-- Budget Gauge Card --%>
            <div class="bg-surface-container-low border-t-2 border-[#00eefc] p-6 hud-border relative overflow-hidden">
              <div class="absolute top-0 right-0 p-2 opacity-20">
                <span class="material-symbols-outlined text-6xl">monitoring</span>
              </div>
              <h3 class="text-[#00eefc] font-mono text-xs tracking-widest uppercase mb-8">BUDGET_GAUGE</h3>
              <div class="flex justify-center items-center py-6 relative">
                <svg class="w-48 h-48 transform -rotate-90">
                  <circle class="text-[#494847]/20" cx="96" cy="96" fill="transparent" r="88" stroke="currentColor" stroke-width="2" />
                  <circle
                    class={if(@status.is_over_budget, do: "text-[#ff725e]", else: "text-[#ffa44c]")}
                    cx="96" cy="96" fill="transparent" r="88" stroke="currentColor"
                    stroke-dasharray="552.92"
                    stroke-dashoffset={552.92 * (1 - min(@spend_pct, 100) / 100)}
                    stroke-width="8"
                  />
                  <circle class="text-[#00eefc]/30" cx="96" cy="96" fill="transparent" r="80" stroke="currentColor" stroke-dasharray="4" stroke-width="1" />
                </svg>
                <div class="absolute inset-0 flex flex-col items-center justify-center">
                  <span class="text-4xl font-black font-mono text-white">
                    ${Float.round(@status.daily_spent * 1.0, 2)}
                  </span>
                  <span class="text-neutral-500 font-mono text-[10px] tracking-widest uppercase">
                    OF ${Float.round(@status.daily_limit * 1.0, 2)} LIMIT
                  </span>
                </div>
              </div>
              <div class="mt-8 grid grid-cols-2 gap-4">
                <div class="bg-black/40 p-3 border-l-2 border-[#ffa44c]">
                  <div class="text-[9px] text-neutral-500 uppercase font-mono">CONSUMPTION</div>
                  <div class={["text-xl font-bold font-mono", if(@status.is_over_budget, do: "text-[#ff725e]", else: "text-[#ffa44c]")]}>
                    {@spend_pct}%
                  </div>
                </div>
                <div class="bg-black/40 p-3 border-l-2 border-[#00eefc]">
                  <div class="text-[9px] text-neutral-500 uppercase font-mono">REMAINING</div>
                  <div class="text-xl font-bold font-mono text-[#00eefc]">
                    ${Float.round(@status.daily_remaining * 1.0, 2)}
                  </div>
                </div>
              </div>
            </div>

            <%!-- Alert Center --%>
            <div :if={@status.is_over_budget} class="bg-surface-container-low border-t-2 border-[#ff7351] p-6 hud-border">
              <h3 class="text-[#ff7351] font-mono text-xs tracking-widest uppercase mb-4 flex items-center gap-2">
                <span class="material-symbols-outlined text-sm">warning</span>
                SYSTEM_ALERTS
              </h3>
              <div class="flex items-start gap-3 bg-[#ff7351]/5 p-3 border border-[#ff7351]/20">
                <span class="text-[#ff7351] font-mono font-black mt-0.5">!</span>
                <div class="flex-1">
                  <div class="text-white font-mono text-[10px] font-bold">BUDGET_EXCEEDED</div>
                  <div class="text-neutral-500 text-[9px]">Daily limit exceeded. Cost tracking continues.</div>
                </div>
              </div>
            </div>

            <%!-- Days selector --%>
            <div class="bg-surface-container-low p-4 hud-border">
              <div class="text-[9px] text-neutral-500 uppercase font-mono mb-3">TIME_RANGE_SELECTOR</div>
              <div class="flex gap-1">
                <button
                  :for={days <- [1, 3, 7, 14, 30]}
                  phx-click="set_budget_days"
                  phx-value-days={days}
                  class={[
                    "px-3 py-1.5 font-mono text-[10px] tracking-widest transition-all",
                    if(@budget_days == days,
                      do: "bg-[#ffa44c] text-black font-bold",
                      else: "border border-[#494847]/30 text-neutral-500 hover:border-[#00eefc] hover:text-[#00eefc]"
                    )
                  ]}
                >
                  {days}D
                </button>
              </div>
            </div>
          </div>

          <%!-- Right Column: Model Breakdown & Tables --%>
          <div class="md:col-span-8 space-y-6">
            <%!-- Spend by Model --%>
            <div class="bg-surface-container-low p-6 border-t-2 border-[#ea8400] hud-border">
              <div class="flex justify-between items-center mb-8">
                <h3 class="text-[#ffa44c] font-mono text-xs tracking-widest uppercase">SPEND_BY_MODEL</h3>
                <div class="flex gap-1">
                  <div class="w-1 h-3 bg-[#ea8400]" />
                  <div class="w-1 h-3 bg-[#ea8400]/40" />
                  <div class="w-1 h-3 bg-[#ea8400]/20" />
                </div>
              </div>
              <div :if={@model_breakdown == []} class="text-center py-8">
                <span class="material-symbols-outlined text-4xl text-[#494847]/30 mb-2">bar_chart</span>
                <p class="text-[10px] font-mono text-neutral-500">NO_COST_DATA_AVAILABLE</p>
              </div>
              <div :if={@model_breakdown != []} class="space-y-6">
                <div :for={row <- @model_breakdown} class="space-y-2">
                  <div class="flex justify-between text-[10px] font-mono tracking-widest">
                    <span class="text-white uppercase">{row.model}</span>
                    <span class="text-[#00eefc]">${Float.round(row.cost, 4)}</span>
                  </div>
                  <div class="w-full h-4 bg-black/40 flex">
                    <div class="h-full bg-[#ffa44c] transition-all duration-300" style={"width: #{BudgetHelpers.model_bar_pct(@model_breakdown, row.cost)}%"} />
                  </div>
                </div>
              </div>
            </div>

            <%!-- Two-Column Tables --%>
            <div class="grid grid-cols-1 xl:grid-cols-2 gap-6">
              <%!-- Spend by Agent --%>
              <div :if={@agents_breakdown != []} class="bg-surface-container-low p-6 border-l border-[#494847]/20 hud-border">
                <h3 class="text-neutral-400 font-mono text-[10px] tracking-widest uppercase mb-4">SPEND_BY_AGENT</h3>
                <div class="overflow-x-auto">
                  <table class="w-full text-left font-mono text-[10px]">
                    <thead class="border-b border-[#494847]/30 text-neutral-500">
                      <tr>
                        <th class="py-2 font-medium">AGENT_ID</th>
                        <th class="py-2 font-medium">EVENTS</th>
                        <th class="py-2 font-medium text-right">LAST_TOOL</th>
                      </tr>
                    </thead>
                    <tbody class="divide-y divide-[#494847]/10 text-white">
                      <tr :for={a <- @agents_breakdown}>
                        <td class="py-3 text-[#00eefc]">{Map.get(a, "agent", "—")}</td>
                        <td class="py-3">{Map.get(a, "events", 0)}</td>
                        <td class="py-3 text-right">
                          <span :if={Map.get(a, "lastTool")} class="text-neutral-500">
                            {Map.get(a, "lastTool")}
                          </span>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>

              <%!-- Spend by Session --%>
              <div :if={@sessions_breakdown != []} class="bg-surface-container-low p-6 border-l border-[#494847]/20 hud-border">
                <h3 class="text-neutral-400 font-mono text-[10px] tracking-widest uppercase mb-4">ACTIVE_SESSIONS</h3>
                <div class="overflow-x-auto">
                  <table class="w-full text-left font-mono text-[10px]">
                    <thead class="border-b border-[#494847]/30 text-neutral-500">
                      <tr>
                        <th class="py-2 font-medium">SESSION</th>
                        <th class="py-2 font-medium text-right">SPENT</th>
                        <th class="py-2 font-medium text-right">EVENTS</th>
                      </tr>
                    </thead>
                    <tbody class="divide-y divide-[#494847]/10 text-white">
                      <tr :for={s <- @sessions_breakdown}>
                        <td class="py-3">{Map.get(s, "session", "—")}</td>
                        <td class="py-3 text-right text-[#00eefc]">${BudgetHelpers.format_cost(Map.get(s, "spent"))}</td>
                        <td class="py-3 text-right">{Map.get(s, "events", 0)}</td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>

            <%!-- Per-task breakdown --%>
            <div :if={@tasks_breakdown != []} class="bg-surface-container-low p-6 border-l border-[#494847]/20 hud-border">
              <h3 class="text-neutral-400 font-mono text-[10px] tracking-widest uppercase mb-4">SPEND_BY_TASK</h3>
              <div class="overflow-x-auto">
                <table class="w-full text-left font-mono text-[10px]">
                  <thead class="border-b border-[#494847]/30 text-neutral-500">
                    <tr>
                      <th class="py-2 font-medium">TASK_ID</th>
                      <th class="py-2 font-medium text-right">EVENTS</th>
                      <th class="py-2 font-medium text-right">LAST_ACTIVITY</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-[#494847]/10 text-white">
                    <tr :for={t <- @tasks_breakdown}>
                      <td class="py-3 text-[#00eefc]">{Map.get(t, "task", "—")}</td>
                      <td class="py-3 text-right">{Map.get(t, "events", 0)}</td>
                      <td class="py-3 text-right text-neutral-500">{format_time(Map.get(t, "lastActivity"))}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        </div>

        <%!-- Recent Cost Events --%>
        <div :if={!@loading} class="bg-surface-container-low border border-[#494847]/10 hud-border overflow-hidden" id="budget-events" phx-hook="Download">
          <div class="p-6 border-b border-[#494847]/10 flex flex-col md:flex-row justify-between items-start md:items-center bg-surface-container gap-3">
            <h3 class="font-headline text-lg font-bold text-white uppercase flex items-center gap-2">
              <span class="w-1.5 h-6 bg-[#ffa44c]" />
              COST_EVENT_LOG
            </h3>
            <div class="flex gap-2 items-center flex-wrap">
              <div class="flex gap-1">
                <.tactical_button variant="ghost" phx-click="export_events" phx-value-format="csv">
                  <span class="material-symbols-outlined text-xs mr-1">download</span> CSV
                </.tactical_button>
                <.tactical_button variant="ghost" phx-click="export_events" phx-value-format="json">
                  <span class="material-symbols-outlined text-xs mr-1">download</span> JSON
                </.tactical_button>
              </div>
              <div class="flex gap-1">
                <button
                  :for={limit <- [25, 50, 100, 200]}
                  phx-click="set_event_limit"
                  phx-value-limit={limit}
                  class={[
                    "px-2 py-1 font-mono text-[10px] transition-all",
                    if(@event_limit == limit,
                      do: "bg-[#ffa44c]/20 text-[#ffa44c] border border-[#ffa44c]/40",
                      else: "text-neutral-500 border border-[#494847]/20 hover:text-[#00eefc]"
                    )
                  ]}
                >
                  {limit}
                </button>
              </div>
            </div>
          </div>
          <div :if={@events == []} class="text-center py-12">
            <span class="material-symbols-outlined text-4xl text-[#494847]/30 mb-2">schedule</span>
            <p class="text-[10px] font-mono text-neutral-500">NO_EVENTS_RECORDED</p>
          </div>
          <div :if={@events != []} class="overflow-x-auto max-h-[500px] overflow-y-auto">
            <table class="w-full text-left font-mono text-[11px]">
              <thead>
                <tr class="bg-black/40 text-[#777575] border-b border-[#494847]/10 uppercase tracking-widest">
                  <th class="px-6 py-4 font-normal">TIMESTAMP</th>
                  <th class="px-6 py-4 font-normal">TOOL</th>
                  <th class="px-6 py-4 font-normal">SESSION</th>
                  <th class="px-6 py-4 font-normal text-right">COST</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-[#494847]/5">
                <tr :for={evt <- @events} class="hover:bg-[#00eefc]/5 transition-colors">
                  <td class="px-6 py-4 text-[#777575]">{format_time(Map.get(evt, :timestamp))}</td>
                  <td class="px-6 py-4 text-white">{Map.get(evt, :tool, "—")}</td>
                  <td class="px-6 py-4 text-white" title={Map.get(evt, :session, "")}>
                    {BudgetHelpers.short_id(Map.get(evt, :session, ""))}
                  </td>
                  <td class="px-6 py-4 text-right text-white">${BudgetHelpers.format_cost(Map.get(evt, :cost_usd))}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <%!-- Telemetry Footer --%>
        <div :if={!@loading} class="grid grid-cols-2 md:grid-cols-4 gap-4">
          <div class="bg-surface-container p-4 border-l-2 border-[#494847]/50">
            <div class="text-[9px] text-neutral-500 uppercase font-mono mb-1">TOTAL_MODELS</div>
            <div class="text-lg font-mono text-white">
              {length(@model_breakdown)}<span class="text-xs text-[#00eefc] ml-1">ACTIVE</span>
            </div>
          </div>
          <div class="bg-surface-container p-4 border-l-2 border-[#494847]/50">
            <div class="text-[9px] text-neutral-500 uppercase font-mono mb-1">SESSIONS</div>
            <div class="text-lg font-mono text-white">
              {length(@sessions_breakdown)}<span class="text-xs text-[#00eefc] ml-1">TRACKED</span>
            </div>
          </div>
          <div class="bg-surface-container p-4 border-l-2 border-[#494847]/50">
            <div class="text-[9px] text-neutral-500 uppercase font-mono mb-1">AGENTS</div>
            <div class="text-lg font-mono text-white">
              {length(@agents_breakdown)}<span class="text-xs text-[#00eefc] ml-1">REPORTING</span>
            </div>
          </div>
          <div class="bg-surface-container p-4 border-l-2 border-[#494847]/50">
            <div class="text-[9px] text-neutral-500 uppercase font-mono mb-1">EVENT_COUNT</div>
            <div class="text-lg font-mono text-white">
              {length(@events)}<span class="text-xs text-[#ffa44c] ml-1">EVENTS</span>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load_scoped_events(limit, nil, nil) do
    safe_call(fn -> BudgetTracker.recent_events(limit) end, [])
  end

  defp load_scoped_events(limit, client_id, workspace) do
    safe_call(
      fn ->
        CostEventReader.all_sessions(
          limit: max(limit * 4, 200),
          client_id: client_id,
          workspace: workspace
        )
      end,
      []
    )
    |> Enum.map(fn session ->
      %{
        timestamp: Map.get(session, :last_seen),
        tool: Map.get(session, :last_tool),
        model_id: Map.get(session, :model_id),
        session: Map.get(session, :session_id),
        cost_usd: Map.get(session, :total_cost_usd, 0.0)
      }
    end)
    |> Enum.take(limit)
  end

end
