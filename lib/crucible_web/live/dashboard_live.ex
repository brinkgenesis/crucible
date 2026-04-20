defmodule CrucibleWeb.DashboardLive do
  @moduledoc """
  Main dashboard LiveView for the orchestration control plane.

  Displays real-time operational metrics: budget expenditure, active/pending/completed/failed
  workflow runs, system health (provider status, circuit breakers), KPI snapshots,
  memory vault statistics, token usage telemetry, cost-by-model breakdown, self-improvement
  hints, and the knowledge loop.

  ## LiveView Lifecycle

  - `mount/3` — subscribes to PubSub topics (`orchestrator:updates`, `budget:updates`,
    `kpi:updates`) and starts a `RefreshTimer` with a 10-second base interval. Initial
    data load runs in parallel via `Task.async`.
  - `handle_params/3` — applies client and workspace scope filters from URL query params,
    then reloads data.
  - `terminate/2` — cancels the refresh timer.

  ## Real-Time Updates

  Three PubSub topics push changes to the dashboard. On each PubSub message the refresh
  timer resets to the base interval and data reloads immediately. Between PubSub events,
  the `RefreshTimer` fires periodic `:refresh` messages with adaptive back-off to keep
  the view current without excessive polling.
  """

  use CrucibleWeb, :live_view

  alias Crucible.{
    BudgetTracker,
    CostEventReader,
    SelfImprovement,
    TraceReader
  }

  alias CrucibleWeb.Live.{RefreshTimer, ScopeFilters}
  alias CrucibleWeb.HealthSnapshot
  alias Phoenix.LiveView.JS
  require Logger

  @refresh_interval 10_000

  @impl true
  def mount(_params, _session, socket) do
    timer =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Crucible.PubSub, "orchestrator:updates")
        Phoenix.PubSub.subscribe(Crucible.PubSub, "budget:updates")
        Phoenix.PubSub.subscribe(Crucible.PubSub, "kpi:updates")
        RefreshTimer.start(@refresh_interval)
      end

    {:ok,
     assign(socket,
       page_title: "Dashboard",
       refresh_timer: timer,
       current_path: "/",
       client_filter: ScopeFilters.all_scope(),
       workspace_filter: ScopeFilters.all_scope(),
       client_options: ScopeFilters.client_options([]),
       workspace_options: ScopeFilters.workspace_options([]),
       system_health: nil,
       loading: !connected?(socket),
       last_updated_at: DateTime.utc_now(),
       failed_sections: []
     )
     |> load_data()}
  end

  @impl true
  def terminate(_reason, socket) do
    RefreshTimer.cancel(socket.assigns[:refresh_timer])
  end

  @impl true
  def handle_params(params, _uri, socket) do
    client_filter = ScopeFilters.normalize_param(params["client_id"])
    workspace_filter = ScopeFilters.normalize_param(params["workspace"])

    {:noreply,
     socket
     |> assign(
       client_filter: client_filter,
       workspace_filter: workspace_filter
     )
     |> load_data()}
  end

  @doc """
  Handles incoming messages for real-time dashboard updates.

  Clauses:

    * `:refresh` — periodic timer tick. Reloads all dashboard data and advances the
      adaptive refresh timer.
    * `{:orchestrator_update, _}` — `orchestrator:updates` PubSub. Resets the refresh
      timer to base interval and reloads data immediately.
    * `{:budget_update, _}` — `budget:updates` PubSub. Resets timer and reloads data.
    * `{:kpi_updated, _}` — `kpi:updates` PubSub. Resets timer and reloads data.
  """
  @impl true
  def handle_info(:refresh, socket) do
    socket = load_data(socket)
    timer = RefreshTimer.tick(socket.assigns[:refresh_timer], true)
    {:noreply, assign(socket, refresh_timer: timer, last_updated_at: DateTime.utc_now())}
  end

  # PubSub events: reset timer to base interval (data just changed)
  def handle_info({:orchestrator_update, _}, socket) do
    timer = RefreshTimer.reset(socket.assigns[:refresh_timer])
    {:noreply, assign(load_data(socket), refresh_timer: timer, last_updated_at: DateTime.utc_now())}
  end

  def handle_info({:budget_update, _}, socket) do
    timer = RefreshTimer.reset(socket.assigns[:refresh_timer])
    {:noreply, assign(load_data(socket), refresh_timer: timer, last_updated_at: DateTime.utc_now())}
  end

  def handle_info({:kpi_updated, _}, socket) do
    timer = RefreshTimer.reset(socket.assigns[:refresh_timer])
    {:noreply, assign(load_data(socket), refresh_timer: timer, last_updated_at: DateTime.utc_now())}
  end

  @doc """
  Handles the `"set_scope_filters"` event from the scope filter bar. Updates client and
  workspace filters by pushing a URL patch with the new query params.
  """
  @impl true
  def handle_event("set_scope_filters", params, socket) do
    client_filter = ScopeFilters.normalize_param(params["client_id"])
    workspace_filter = ScopeFilters.normalize_param(params["workspace"])

    {:noreply, push_patch(socket, to: dashboard_path(client_filter, workspace_filter))}
  end

  defp load_data(socket) do
    client_filter = socket.assigns[:client_filter] || ScopeFilters.all_scope()
    workspace_filter = socket.assigns[:workspace_filter] || ScopeFilters.all_scope()
    client_id = ScopeFilters.query_value(client_filter)
    workspace = ScopeFilters.query_value(workspace_filter)

    # Parallelize independent data fetches — cuts latency from ~9 serial calls to ~3 parallel groups
    tasks = %{
      budget: Task.async(fn -> safe_call(fn -> BudgetTracker.status() end, %{daily_spent: 0.0, daily_limit: 100.0, daily_remaining: 100.0, is_over_budget: false}) end),
      unfiltered_runs: Task.async(fn -> safe_call(fn -> TraceReader.list_runs() end, []) end),
      trace_runs: Task.async(fn -> safe_call(fn -> TraceReader.list_runs(client_id: client_id, workspace: workspace) end, []) end),
      run_source: Task.async(fn -> safe_call(fn -> TraceReader.list_runs_source(client_id: client_id, workspace: workspace) end, %{source: :unknown, confidence: "low"}) end),
      kpi: Task.async(fn -> safe_call(fn -> SelfImprovement.latest_snapshot() end, nil) end),
      knowledge_loop: Task.async(fn -> safe_call(fn -> SelfImprovement.knowledge_loop() end, nil) end),
      hints: Task.async(fn -> safe_call(fn -> SelfImprovement.current_hints() end, %{}) end),
      events: Task.async(fn -> safe_call(fn -> BudgetTracker.recent_events(50) end, []) end),
      memory_stats: Task.async(fn -> count_memory_notes() end),
      cost_stats: Task.async(fn -> safe_call(fn -> CostEventReader.stats(client_id: client_id) end, %{total_sessions: 0, total_tool_calls: 0, total_cost: 0.0}) end),
      sessions: Task.async(fn -> safe_call(fn -> CostEventReader.all_sessions(client_id: client_id, workspace: workspace) end, []) end),
      cost_source: Task.async(fn -> safe_call(fn -> CostEventReader.source_status(client_id: client_id, workspace: workspace) end, %{source: :unknown, confidence: "low"}) end)
    }

    # Await all — 5s timeout matches refresh interval
    # Await with timeout protection — don't crash LiveView if a data source is slow.
    # A source is only counted as "failed" when it times out; nil results from a
    # successful call (e.g. no KPI snapshot yet) are a legitimate empty state.
    {results, failed_sections} =
      Enum.reduce(tasks, {%{}, []}, fn {k, task}, {acc, failed} ->
        try do
          {Map.put(acc, k, Task.await(task, 5_000)), failed}
        catch
          :exit, _ ->
            Task.shutdown(task, :brutal_kill)
            Logger.warning("Dashboard: task #{k} timed out")
            {Map.put(acc, k, nil), [k | failed]}
        end
      end)

    budget = results.budget || %{daily_spent: 0.0, daily_limit: 100.0, daily_remaining: 100.0, is_over_budget: false}
    unfiltered_scope_runs = results.unfiltered_runs || []
    trace_runs = (results.trace_runs || []) |> maybe_filter_workspace(workspace_filter)
    runs = Enum.map(trace_runs, &trace_run_to_dashboard_row/1)
    hints_data = results.hints
    hints = if is_map(hints_data), do: Map.get(hints_data, :global, []), else: []
    events = results.events || []
    sessions = (results.sessions || []) |> filter_sessions_by_workspace(trace_runs, workspace_filter)

    active_runs =
      Enum.count(trace_runs, &(normalize_run_status(&1.status) in ["running", "in_progress"]))

    pending_runs = Enum.count(trace_runs, &(normalize_run_status(&1.status) == "pending"))

    completed_runs =
      Enum.count(trace_runs, &(normalize_run_status(&1.status) in ["done", "completed"]))

    failed_runs = Enum.count(trace_runs, &(normalize_run_status(&1.status) == "failed"))

    system_health =
      HealthSnapshot.build_full_health(
        budget: HealthSnapshot.budget_status_from_struct(budget),
        runs: Enum.map(trace_runs, &trace_run_to_health_row/1)
      )

    model_breakdown =
      events
      |> Enum.filter(&Map.has_key?(&1, :model_id))
      |> Enum.group_by(& &1.model_id)
      |> Enum.map(fn {model, evts} ->
        total = evts |> Enum.map(&(Map.get(&1, :cost_usd, 0) || 0)) |> Enum.sum()
        %{model: model, cost: total * 1.0, count: length(evts)}
      end)
      |> Enum.sort_by(& &1.cost, :desc)

    total_tokens = Enum.reduce(trace_runs, 0, &((&1.total_tokens || 0) + &2))
    total_cost_usd = Enum.reduce(trace_runs, 0.0, &((&1.total_cost_usd || 0.0) + &2))

    api_sessions = Enum.count(sessions, &(Map.get(&1, :execution_type) == "api"))
    sub_sessions = Enum.count(sessions, &(Map.get(&1, :execution_type) == "subscription"))

    review_runs = Enum.count(trace_runs, &(normalize_run_status(&1.status) == "review"))

    client_options =
      unfiltered_scope_runs
      |> Enum.map(&Map.get(&1, :client_id))
      |> ScopeFilters.client_options()

    workspace_options =
      unfiltered_scope_runs
      |> Enum.map(&run_workspace/1)
      |> ScopeFilters.workspace_options()

    assign(socket,
      budget: budget,
      runs: runs,
      active_runs: active_runs,
      pending_runs: pending_runs,
      completed_runs: completed_runs,
      failed_runs: failed_runs,
      review_runs: review_runs,
      kpi: results.kpi,
      knowledge_loop: results.knowledge_loop,
      hints: hints,
      model_breakdown: model_breakdown,
      system_health: system_health,
      memory_stats: results.memory_stats,
      cost_stats: results.cost_stats,
      total_tokens: total_tokens,
      total_cost_usd: total_cost_usd,
      api_sessions: api_sessions,
      sub_sessions: sub_sessions,
      run_source: results.run_source,
      cost_source: results.cost_source,
      client_options: client_options,
      workspace_options: workspace_options,
      loading: false,
      failed_sections: failed_sections
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-8">
        <.scope_filter_bar
          event="set_scope_filters"
          client_filter={@client_filter}
          workspace_filter={@workspace_filter}
          client_options={@client_options}
          workspace_options={@workspace_options}
        />

        <div :if={!@loading} class="flex flex-wrap items-center justify-between gap-3">
          <div class="flex flex-wrap items-center gap-3 font-label text-[10px] tracking-widest">
            <span class={["px-2 py-0.5 border", source_hud_class(@run_source.confidence)]}>
              RUNS_SOURCE: {source_label(@run_source.source) |> String.upcase()}
            </span>
            <span class={["px-2 py-0.5 border", source_hud_class(@cost_source.confidence)]}>
              SESSIONS_SOURCE: {source_label(@cost_source.source) |> String.upcase()}
            </span>
          </div>
          <.last_updated at={@last_updated_at} />
        </div>

        <%!-- Section error indicators --%>
        <div :if={@failed_sections != []} class="space-y-1">
          <.section_error :for={section <- @failed_sections} label={section |> to_string() |> String.upcase()} />
        </div>

        <%!-- Loading skeleton --%>
        <div :if={@loading} class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
          <div :for={_ <- 1..4} class="bg-surface-container-low p-5 hud-border animate-pulse">
            <div class="h-16 bg-surface-container-high" />
          </div>
        </div>

        <%!-- STAT CARDS --%>
        <div :if={!@loading} class="grid grid-cols-1 md:grid-cols-4 gap-6">
          <.hud_stat
            label="BUDGET_EXPENDITURE"
            value={"$#{Float.round(@budget.daily_spent * 1.0, 2)}"}
            color={if @budget.is_over_budget, do: "tertiary", else: "primary"}
          >
            <div class="mt-3 h-1 bg-surface-container-high w-full">
              <div
                class="h-full bg-[#ffa44c] shadow-[0_0_8px_#ffa44c]"
                style={"width: #{budget_pct(@budget)}%"}
              />
            </div>
          </.hud_stat>

          <.hud_card accent="secondary">
            <div class="text-xs font-label text-[#00eefc]/60 mb-2 tracking-widest">ACTIVE_RUNS</div>
            <div class="text-3xl font-headline font-bold text-[#00eefc] tracking-tighter">{@active_runs}</div>
            <div class="flex items-center gap-2 mt-2 text-[10px] font-label text-[#00eefc]">
              <span class="w-2 h-2 bg-[#00eefc] animate-pulse"></span>
              {@pending_runs} PENDING
            </div>
          </.hud_card>

          <.hud_stat label="COMPLETED_TASKS" value={to_string(@completed_runs)} />

          <.hud_card accent="tertiary">
            <div class="text-xs font-label text-[#ff725e]/60 mb-2 tracking-widest">SYSTEM_FAILURES</div>
            <div class="text-3xl font-headline font-bold text-[#ff725e] tracking-tighter">{@failed_runs}</div>
            <div :if={@failed_runs > 0} class="mt-2 text-[10px] font-label text-[#ff725e]/80 flex items-center gap-1">
              <span class="material-symbols-outlined text-xs">warning</span> CRITICAL_STATE_DETECTED
            </div>
          </.hud_card>
        </div>

        <%!-- WORKFLOW PIPELINE STATUS --%>
        <.hud_card :if={!@loading}>
          <.hud_header icon="account_tree" label="WORKFLOW_PIPELINE_STATUS">
            <:actions>
              <span class="text-[10px] font-label text-[#00eefc]">AUTO_REFRESH: 5s</span>
            </:actions>
          </.hud_header>
          <div class="grid grid-cols-5 gap-4">
            <.pipeline_column label="PENDING_QUEUE" count={@pending_runs} color="primary" />
            <.pipeline_column label="ACTIVE_RUNNING" count={@active_runs} color="secondary" active={true} />
            <.pipeline_column label="PENDING_REVIEW" count={@review_runs} color="primary" />
            <.pipeline_column label="COMPLETED_DONE" count={@completed_runs} color="primary" />
            <.pipeline_column label="FAILED_ABORT" count={@failed_runs} color="tertiary" />
          </div>
        </.hud_card>

        <div :if={!@loading} class="grid grid-cols-12 gap-8">
          <%!-- SYSTEM HEALTH & KPI --%>
          <div class="col-span-12 lg:col-span-4 space-y-8">
            <%!-- System Health Monitor --%>
            <.hud_card>
              <.hud_header icon="monitor_heart" label="SYSTEM_HEALTH_MONITOR" />
              <div :if={@system_health} class="grid grid-cols-2 gap-y-4">
                <div
                  :for={{provider, online} <- @system_health["router"] || %{}}
                  class="flex items-center gap-3"
                >
                  <span class={[
                    "w-3 h-3",
                    health_indicator_class(online)
                  ]} />
                  <span class="text-[10px] font-label text-white/70">{provider}</span>
                </div>
                <div :if={@system_health["router"] == nil || @system_health["router"] == %{}}
                  class="col-span-2 text-[10px] font-label text-white/40">
                  NO_PROVIDERS_DETECTED
                </div>
              </div>
              <%!-- Circuit Breakers --%>
              <div :if={circuit_issues?(@system_health && @system_health["circuits"])} class="mt-4 pt-4 border-t border-white/5">
                <div class="text-[10px] font-label text-[#ff725e]/80 tracking-widest mb-2">CIRCUIT_BREAKERS</div>
                <div class="flex flex-wrap gap-2">
                  <span
                    :for={{provider, info} <- (@system_health && @system_health["circuits"]) || %{}}
                    :if={is_map(info) && Map.get(info, "state") != "closed"}
                    class="text-[9px] font-label px-2 py-0.5 border border-[#ff725e]/30 text-[#ff725e]"
                  >
                    {provider}: {Map.get(info, "state")}
                  </span>
                </div>
              </div>
            </.hud_card>

            <%!-- KPI Snapshot --%>
            <.hud_card :if={@kpi}>
              <.hud_header icon="analytics" label="KPI_SNAPSHOT" />
              <div class="space-y-5">
                <.kpi_row label="TOTAL_RUNS" value={to_string(@kpi[:total_runs] || 0)} color="white" />
                <.kpi_row label="FAIL_RATE" value={format_pct(@kpi[:fail_rate])} color="tertiary" />
                <.kpi_row label="TIMEOUT_PROB" value={format_pct(@kpi[:timeout_rate])} color="primary" />
                <.kpi_row label="TOTAL_COST" value={"$#{format_cost(@kpi[:total_cost_usd])}"} color="secondary" />
              </div>
            </.hud_card>
          </div>

          <%!-- MEMORY VAULT & TOKEN USAGE --%>
          <div class="col-span-12 lg:col-span-8 grid grid-cols-2 gap-8">
            <%!-- Memory Vault --%>
            <.hud_card>
              <.hud_header icon="psychology" label="MEMORY_VAULT_SCAN">
                <:actions>
                  <.link navigate="/memory" class="text-[10px] font-label text-[#00eefc] border border-[#00eefc]/30 px-3 py-1 hover:bg-[#00eefc]/10">
                    VIEW_VAULT
                  </.link>
                </:actions>
              </.hud_header>
              <div class="flex items-center gap-6 mb-8">
                <div class="relative w-24 h-24 border-2 border-[#ffa44c]/20 flex items-center justify-center">
                  <div class="absolute inset-0 bg-[#ffa44c]/5 animate-pulse"></div>
                  <div class="text-center relative z-10">
                    <div class="text-2xl font-headline font-bold text-[#ffa44c]">{format_large_number(@memory_stats.total)}</div>
                    <div class="text-[8px] font-label text-[#ffa44c]/60">TOTAL_NOTES</div>
                  </div>
                </div>
                <div class="flex-1 space-y-3">
                  <div :for={{type, count} <- Enum.sort_by(@memory_stats.by_type, fn {_, c} -> -c end) |> Enum.take(3)}>
                    <div class="flex justify-between text-[9px] font-label text-white/60 mb-1">
                      <span>{String.upcase(type)}</span>
                      <span>{type_pct(@memory_stats.total, count)}%</span>
                    </div>
                    <div class="h-1 bg-surface-container-high w-full">
                      <div class="h-full bg-[#00eefc]" style={"width: #{type_pct(@memory_stats.total, count)}%"} />
                    </div>
                  </div>
                </div>
              </div>
            </.hud_card>

            <%!-- Token Usage --%>
            <.hud_card>
              <.hud_header icon="token" label="TOKEN_USAGE_TELEMETRY">
                <:actions>
                  <.link navigate="/cost" class="text-[10px] font-label text-[#00eefc] border border-[#00eefc]/30 px-3 py-1 hover:bg-[#00eefc]/10">
                    DETAILS
                  </.link>
                </:actions>
              </.hud_header>
              <div class="space-y-4">
                <div class="flex justify-between items-center">
                  <div class="text-[10px] font-label text-[#00eefc] uppercase">TOTAL_TOKENS</div>
                  <div class="text-lg font-headline font-bold text-[#00eefc]">{format_large_number(@total_tokens)}</div>
                </div>
                <div class="flex justify-between items-center">
                  <div class="text-[10px] font-label text-[#ffa44c] uppercase">API_COST</div>
                  <div class="text-lg font-headline font-bold text-[#ffa44c]">${Float.round(@total_cost_usd * 1.0, 2)}</div>
                </div>
                <div class="pt-4 border-t border-white/5">
                  <div class="flex justify-between items-center text-[10px] font-label text-white/40">
                    <span>API_SESSIONS: {@api_sessions}</span>
                    <span>SUB_SESSIONS: {@sub_sessions}</span>
                  </div>
                </div>
              </div>
            </.hud_card>

            <%!-- Cost by Model --%>
            <div class="col-span-2">
              <.hud_card :if={@model_breakdown != []}>
                <.hud_header icon="payments" label="COST_EXPENDITURE_BY_MODEL">
                  <:actions>
                    <.link navigate="/budget" class="text-[10px] font-label text-[#00eefc] border border-[#00eefc]/30 px-3 py-1 hover:bg-[#00eefc]/10">
                      DETAILS
                    </.link>
                  </:actions>
                </.hud_header>
                <div class="space-y-6">
                  <div :for={row <- Enum.take(@model_breakdown, 5)} class="grid grid-cols-12 items-center gap-4">
                    <div class="col-span-3 text-[10px] font-label text-white/70 truncate" title={row.model}>{row.model}</div>
                    <div class="col-span-7 h-2 bg-surface-container-high relative">
                      <div class="absolute inset-y-0 left-0 bg-[#ffa44c]" style={"width: #{model_bar_pct(@model_breakdown, row.cost)}%"} />
                    </div>
                    <div class="col-span-2 text-right text-[10px] font-label text-[#ffa44c]">${Float.round(row.cost, 2)}</div>
                  </div>
                </div>
              </.hud_card>
            </div>
          </div>
        </div>

        <%!-- HINTS / ALERTS --%>
        <.hud_card :if={@hints != []} accent="tertiary">
          <.hud_header icon="lightbulb" label="SELF_IMPROVEMENT_HINTS" />
          <div class="space-y-2">
            <div :for={hint <- @hints} class="flex items-start gap-2 text-xs font-label text-white/70">
              <span class="material-symbols-outlined text-[#ffa44c] text-sm mt-0.5">arrow_right</span>
              {hint}
            </div>
          </div>
        </.hud_card>

        <%!-- Knowledge Loop --%>
        <.hud_card :if={@knowledge_loop}>
          <.hud_header icon="hub" label="KNOWLEDGE_LOOP" />
          <div class="grid grid-cols-2 md:grid-cols-4 gap-6">
            <div>
              <div class="text-[10px] font-label text-white/40 uppercase tracking-widest mb-1">LEARN</div>
              <div class="text-xl font-headline font-bold text-white">{@knowledge_loop[:learn_count] || 0}</div>
              <div class="text-[9px] font-label text-white/30 mt-1">LESSONS + OBSERVATIONS</div>
            </div>
            <div>
              <div class="text-[10px] font-label text-white/40 uppercase tracking-widest mb-1">CREATE</div>
              <div class="text-xl font-headline font-bold text-white">{@knowledge_loop[:create_count] || 0}</div>
              <div class="text-[9px] font-label text-white/30 mt-1">DECISIONS</div>
            </div>
            <div>
              <div class="text-[10px] font-label text-white/40 uppercase tracking-widest mb-1">SHARE</div>
              <div class="text-xl font-headline font-bold text-white">{@knowledge_loop[:share_count] || 0}</div>
              <div class="text-[9px] font-label text-white/30 mt-1">HANDOFFS</div>
            </div>
            <div>
              <div class="text-[10px] font-label text-white/40 uppercase tracking-widest mb-1">COMPLETENESS</div>
              <div class={["text-xl font-headline font-bold", loop_hud_color(@knowledge_loop[:loop_completeness])]}>
                {format_pct(@knowledge_loop[:loop_completeness])}
              </div>
            </div>
          </div>
          <div :if={(@knowledge_loop[:stalled_stages] || []) != []} class="mt-4 flex gap-2">
            <span
              :for={stage <- @knowledge_loop[:stalled_stages]}
              class="text-[9px] font-label px-2 py-0.5 border border-[#ffa44c]/30 text-[#ffa44c]"
            >
              {String.upcase(to_string(stage))} STALLED
            </span>
          </div>
        </.hud_card>

        <%!-- RECENT RUNS TABLE --%>
        <.hud_card>
          <div class="flex justify-between items-center mb-6">
            <h3 class="font-headline font-bold text-[#ffa44c] text-xs tracking-[0.2em] uppercase flex items-center gap-2">
              <span class="material-symbols-outlined text-base">receipt_long</span> RECENT_OPERATIONAL_RUNS
            </h3>
            <.link navigate="/runs" class="text-[10px] font-label text-[#00eefc] border border-[#00eefc]/30 px-3 py-1 hover:bg-[#00eefc]/10">
              VIEW_FULL_LOGS
            </.link>
          </div>

          <div :if={@runs == []} class="text-center py-8">
            <span class="material-symbols-outlined text-4xl text-[#ffa44c]/20">play_circle</span>
            <p class="text-[10px] font-label text-white/30 mt-2">NO_WORKFLOW_RUNS_DETECTED</p>
          </div>

          <div :if={@runs != []} class="overflow-x-auto">
            <table class="w-full text-left font-label">
              <thead>
                <tr class="bg-surface-container-high/50 text-[10px] text-white/40 uppercase tracking-widest">
                  <th class="px-6 py-4 font-normal">RUN_ID</th>
                  <th class="px-6 py-4 font-normal">WORKFLOW_TYPE</th>
                  <th class="px-6 py-4 font-normal">STATUS</th>
                  <th class="px-6 py-4 font-normal text-right">PHASES</th>
                </tr>
              </thead>
              <tbody class="text-xs divide-y divide-white/5">
                <tr
                  :for={run <- Enum.take(@runs, 5)}
                  class="hover:bg-white/5 transition-colors cursor-pointer"
                  phx-click={JS.navigate("/runs/#{run.id}")}
                >
                  <td class="px-6 py-4 text-[#00eefc] font-label" title={run.id}>
                    #{String.slice(run.id, 0, 12)}
                  </td>
                  <td class="px-6 py-4 text-white/80 uppercase">{run.workflow_type}</td>
                  <td class="px-6 py-4"><.status_badge status={run.status} /></td>
                  <td class="px-6 py-4 text-right text-white/60">{run.phase_count}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.hud_card>
      </div>
    </Layouts.app>
    """
  end

  # --- Render helpers ---

  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :color, :string, default: "primary"
  attr :active, :boolean, default: false

  defp pipeline_column(assigns) do
    {bg_class, text_class, border_class} =
      case assigns.color do
        "secondary" -> {"bg-[#00eefc]/10", "text-[#00eefc]", "border-[#00eefc]"}
        "tertiary" -> {"bg-[#ff725e]/10", "text-[#ff725e]", "border-[#ff725e]"}
        _ -> {"bg-surface-container-high", "text-[#ffa44c]/70", "border-[#ffa44c]/30"}
      end

    assigns = assign(assigns, bg_class: bg_class, text_class: text_class, border_class: border_class)

    ~H"""
    <div class="space-y-3">
      <div class={["p-2 text-[10px] font-label border-b", @bg_class, @text_class, @border_class]}>
        {@label} [{@count}]
      </div>
      <div :if={@count > 0} class={[
        "h-24 bg-surface-container-lowest border p-3 flex flex-col justify-between",
        if(@active, do: "border-[#00eefc]/30 relative overflow-hidden", else: "border-white/5")
      ]}>
        <div :if={@active} class="absolute inset-0 bg-[#00eefc]/5 animate-pulse"></div>
        <div class={["text-[9px] font-label", @text_class]}>{@count} ITEMS</div>
        <div class={["h-1 w-full", if(@active, do: "bg-[#00eefc]", else: "bg-[#ffa44c]/20")]} />
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :color, :string, default: "white"

  defp kpi_row(assigns) do
    value_class =
      case assigns.color do
        "tertiary" -> "text-[#ff725e]"
        "secondary" -> "text-[#00eefc]"
        "primary" -> "text-[#ffa44c]"
        _ -> "text-white"
      end

    assigns = assign(assigns, :value_class, value_class)

    ~H"""
    <div class="flex justify-between items-end border-b border-white/5 pb-2">
      <span class="text-[10px] font-label text-white/40 uppercase">{@label}</span>
      <span class={["text-xl font-headline font-bold", @value_class]}>{@value}</span>
    </div>
    """
  end

  defp budget_pct(budget) do
    if budget.daily_limit > 0,
      do: min(Float.round(budget.daily_spent / budget.daily_limit * 100.0, 0), 100),
      else: 0
  end

  defp type_pct(total, count) when total > 0, do: round(count / total * 100)
  defp type_pct(_, _), do: 0

  defp health_indicator_class(true), do: "bg-[#00FF41] shadow-[0_0_8px_#00FF41]"
  defp health_indicator_class(_), do: "bg-[#ff725e] shadow-[0_0_8px_#ff725e]"

  defp loop_hud_color(nil), do: "text-white/50"
  defp loop_hud_color(val) when val >= 1.0, do: "text-[#00FF41]"
  defp loop_hud_color(val) when val >= 0.66, do: "text-[#ffa44c]"
  defp loop_hud_color(_val), do: "text-[#ff725e]"

  defp source_hud_class("high"), do: "border-[#00FF41]/30 text-[#00FF41]"
  defp source_hud_class("medium"), do: "border-[#ffa44c]/30 text-[#ffa44c]"
  defp source_hud_class(_), do: "border-[#ff725e]/30 text-[#ff725e]"

  defp format_pct(nil), do: "—"
  defp format_pct(val) when is_number(val), do: "#{Float.round(val * 100.0, 1)}%"

  defp format_cost(nil), do: "—"
  defp format_cost(val) when is_number(val), do: Float.round(val * 1.0, 2) |> to_string()


  defp model_bar_pct(breakdown, cost) do
    max_cost = breakdown |> Enum.map(& &1.cost) |> Enum.max(fn -> 1 end)
    if max_cost > 0, do: Float.round(cost / max_cost * 100.0, 1), else: 0
  end

  defp trace_run_to_dashboard_row(trace_run) do
    %{
      id: trace_run.run_id,
      workflow_type: trace_run.workflow_name || trace_run.run_id,
      status: normalize_run_status(trace_run.status),
      phase_count: trace_run.phase_count || 0
    }
  end

  defp trace_run_to_health_row(trace_run) do
    %{
      status: normalize_run_status_atom(trace_run.status),
      started_at: trace_run.started_at
    }
  end

  defp normalize_run_status(status) when is_atom(status), do: Atom.to_string(status)
  defp normalize_run_status(status) when is_binary(status), do: status
  defp normalize_run_status(_), do: "unknown"

  defp normalize_run_status_atom(status) do
    case normalize_run_status(status) do
      "pending" -> :pending
      "running" -> :running
      "in_progress" -> :in_progress
      "review" -> :review
      "failed" -> :failed
      "orphaned" -> :orphaned
      "cancelled" -> :cancelled
      "budget_paused" -> :budget_paused
      "completed" -> :completed
      "done" -> :done
      _ -> :unknown
    end
  end

  defp count_memory_notes do
    config = Application.get_env(:crucible, :orchestrator, [])
    repo_root = Keyword.get(config, :repo_root, File.cwd!())
    vault_path = Path.join(repo_root, "memory")

    if File.dir?(vault_path) do
      {total, by_type} = count_vault_files(vault_path)
      %{total: total, by_type: by_type, path: vault_path}
    else
      %{total: 0, by_type: %{}, path: vault_path}
    end
  rescue
    _ -> %{total: 0, by_type: %{}, path: ""}
  end

  defp count_vault_files(vault_path) do
    vault_path
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(vault_path, &1)))
    |> Enum.reject(&(&1 in [".", "..", ".vectors", ".obsidian"]))
    |> Enum.reduce({0, %{}}, fn dir, {total, by_type} ->
      dir_path = Path.join(vault_path, dir)
      count = dir_path |> File.ls!() |> Enum.count(&String.ends_with?(&1, ".md"))
      {total + count, Map.put(by_type, dir, count)}
    end)
  rescue
    _ -> {0, %{}}
  end

  defp circuit_issues?(nil), do: false

  defp circuit_issues?(circuits) when is_map(circuits) do
    Enum.any?(circuits, fn {_k, v} ->
      is_map(v) && Map.get(v, "state") != "closed"
    end)
  end

  defp circuit_issues?(_), do: false

  defp format_large_number(n) when is_integer(n) and n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end

  defp format_large_number(n) when is_integer(n) and n >= 1_000 do
    "#{Float.round(n / 1_000, 1)}K"
  end

  defp format_large_number(n), do: to_string(n)

  defp maybe_filter_workspace(runs, workspace_filter) do
    Enum.filter(runs, fn run ->
      ScopeFilters.matches_workspace?(run_workspace(run), workspace_filter)
    end)
  end

  defp filter_sessions_by_workspace(sessions, trace_runs, workspace_filter) do
    run_workspaces =
      Map.new(trace_runs, fn run -> {Map.get(run, :run_id), run_workspace(run)} end)

    Enum.filter(sessions, fn session ->
      case Map.get(session, :run_id) do
        nil ->
          ScopeFilters.matches_workspace?(nil, workspace_filter)

        run_id ->
          ScopeFilters.matches_workspace?(Map.get(run_workspaces, run_id), workspace_filter)
      end
    end)
  end

  defp dashboard_path(client_filter, workspace_filter) do
    query =
      %{}
      |> ScopeFilters.apply_scope_query(client_filter, workspace_filter)

    "/" <> encode_query(query)
  end

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
