defmodule CrucibleWeb.RunsLive do
  @moduledoc """
  LiveView for the workflow runs dashboard.

  Displays active and completed workflow runs with real-time updates via PubSub,
  supports filtering by client and workspace, run detail drill-down with trace
  timeline, session log viewing, and CSV/JSON export.
  """

  use CrucibleWeb, :live_view
  require Logger

  alias Crucible.{Orchestrator, Repo, TraceReader}
  alias Crucible.Schema.WorkflowRun
  alias CrucibleWeb.Live.{RefreshTimer, ScopeFilters}
  import Ecto.Query

  @refresh_interval 5_000
  @terminal_statuses ~w(done failed cancelled orphaned)
  @completed_ttl_ms :timer.hours(24)

  @doc """
  Mounts the LiveView, subscribing to orchestrator and trace PubSub topics
  and initializing assigns with empty run lists and default filter state.
  """
  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    timer =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Crucible.PubSub, "orchestrator:updates")
        Phoenix.PubSub.subscribe(Crucible.PubSub, "orchestrator:traces")
        expire_stale_runs()
        RefreshTimer.start(@refresh_interval)
      end

    {:ok,
     assign(socket,
       page_title: "Runs",
       refresh_timer: timer,
       current_path: "/runs",
       client_filter: ScopeFilters.all_scope(),
       workspace_filter: ScopeFilters.all_scope(),
       client_options: ScopeFilters.client_options([]),
       workspace_options: ScopeFilters.workspace_options([]),
       runs: [],
       active_runs: [],
       completed_runs: [],
       all_completed_runs: [],
       hidden_completed_count: 0,
       show_all_completed: false,
       selected: nil,
       trace_events: [],
       active_tab: "timeline",
       session_log: nil,
       session_log_phase: nil,
       last_updated_at: DateTime.utc_now()
     )}
  end

  @doc "Cancels the refresh timer on LiveView termination."
  @impl true
  @spec terminate(term(), Phoenix.LiveView.Socket.t()) :: :ok
  def terminate(_reason, socket) do
    RefreshTimer.cancel(socket.assigns[:refresh_timer])
  end

  @doc """
  Handles URL params to load run detail or list view.

  When an `id` param is present, subscribes to run-specific PubSub events and
  loads trace events for the selected run. Applies client/workspace scope filters.
  """
  @impl true
  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_params(%{"id" => id} = params, _uri, socket) do
    client_filter = ScopeFilters.normalize_param(params["client_id"])
    workspace_filter = ScopeFilters.normalize_param(params["workspace"])

    # Subscribe to run-specific events for real-time updates on detail view
    prev_id = socket.assigns[:selected] && socket.assigns.selected.id
    if prev_id && prev_id != id do
      Phoenix.PubSub.unsubscribe(Crucible.PubSub, "run:#{prev_id}")
    end
    if connected?(socket), do: Phoenix.PubSub.subscribe(Crucible.PubSub, "run:#{id}")

    all_runs = safe_list_runs()
    runs = apply_scope_filters(all_runs, client_filter, workspace_filter)
    selected = Enum.find(all_runs, &(&1.id == id))
    trace_events = if selected, do: TraceReader.events_for_run(id), else: []

    {:noreply,
     socket
     |> assign(
       live_params: params,
       client_filter: client_filter,
       workspace_filter: workspace_filter,
       client_options: build_client_options(all_runs),
       workspace_options: build_workspace_options(all_runs),
       runs: runs,
       selected: selected,
       trace_events: trace_events,
       current_path: runs_path(id, client_filter, workspace_filter),
       session_log: nil,
       session_log_phase: nil,
       active_tab: "timeline"
     )
     |> assign_partitioned_runs(runs)}
  end

  def handle_params(params, _uri, socket) do
    client_filter = ScopeFilters.normalize_param(params["client_id"])
    workspace_filter = ScopeFilters.normalize_param(params["workspace"])
    all_runs = safe_list_runs()
    runs = apply_scope_filters(all_runs, client_filter, workspace_filter)

    {:noreply,
     socket
     |> assign(
       live_params: params,
       client_filter: client_filter,
       workspace_filter: workspace_filter,
       client_options: build_client_options(all_runs),
       workspace_options: build_workspace_options(all_runs),
       current_path: runs_path(nil, client_filter, workspace_filter),
       runs: runs,
       selected: nil,
       trace_events: [],
       session_log: nil,
       session_log_phase: nil
     )
     |> assign_partitioned_runs(runs)}
  end

  @doc """
  Handles periodic and event-driven refresh of run data.

  Re-fetches all runs, updates scope filters, and refreshes the selected run's
  trace events if a detail view is active.
  """
  @impl true
  def handle_info(:refresh, socket) do
    all_runs = safe_list_runs()

    runs =
      apply_scope_filters(all_runs, socket.assigns.client_filter, socket.assigns.workspace_filter)

    {selected, trace_events} =
      if socket.assigns.selected do
        sel = Enum.find(all_runs, &(&1.id == socket.assigns.selected.id))
        events = if sel, do: TraceReader.events_for_run(sel.id), else: []
        {sel, events}
      else
        {nil, []}
      end

    timer = RefreshTimer.tick(socket.assigns[:refresh_timer], true)

    {:noreply,
     socket
     |> assign(
       runs: runs,
       selected: selected,
       trace_events: trace_events,
       refresh_timer: timer,
       client_options: build_client_options(all_runs),
       workspace_options: build_workspace_options(all_runs),
       last_updated_at: DateTime.utc_now()
     )
     |> assign_partitioned_runs(runs)}
  end

  # PubSub events: reset timer to base interval
  def handle_info({:orchestrator_update, _}, socket) do
    timer = RefreshTimer.reset(socket.assigns[:refresh_timer])
    send(self(), :refresh)
    {:noreply, assign(socket, refresh_timer: timer, last_updated_at: DateTime.utc_now())}
  end

  # Real-time run event from PubSub "run:{id}"
  def handle_info({:run_event, _run_id, _event_type, _data}, socket) do
    timer = RefreshTimer.reset(socket.assigns[:refresh_timer])
    send(self(), :refresh)
    {:noreply, assign(socket, refresh_timer: timer, last_updated_at: DateTime.utc_now())}
  end

  def handle_info({:trace_event, event}, socket) do
    run_id = socket.assigns.selected && socket.assigns.selected.id
    event_run_id = Map.get(event, :runId) || Map.get(event, "runId")

    if run_id && event_run_id == run_id do
      normalized = stringify_keys(event)
      events = socket.assigns.trace_events ++ [normalized]
      {:noreply, assign(socket, trace_events: events)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @doc """
  Handles UI events including run cancellation, scope filtering, tab switching,
  session log viewing, CSV/JSON export, and toggling completed run visibility.
  """
  @impl true
  def handle_event("cancel_run", %{"id" => id}, socket) do
    case Orchestrator.cancel_run(id) do
      :ok ->
        all_runs = safe_list_runs()

        runs =
          apply_scope_filters(
            all_runs,
            socket.assigns.client_filter,
            socket.assigns.workspace_filter
          )

        {:noreply,
         socket
         |> put_flash(:info, "Run cancelled")
         |> assign(
           runs: runs,
           client_options: build_client_options(all_runs),
           workspace_options: build_workspace_options(all_runs)
         )
         |> assign_partitioned_runs(runs)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  def handle_event("set_scope_filters", params, socket) do
    client_filter = ScopeFilters.normalize_param(params["client_id"])
    workspace_filter = ScopeFilters.normalize_param(params["workspace"])
    selected_id = socket.assigns.selected && socket.assigns.selected.id

    {:noreply, push_patch(socket, to: runs_path(selected_id, client_filter, workspace_filter))}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  def handle_event("view_session_log", %{"phase-id" => phase_id}, socket) do
    run_id = socket.assigns.selected.id
    log = TraceReader.session_log(run_id, phase_id)
    {:noreply, assign(socket, session_log: log, session_log_phase: phase_id)}
  end

  def handle_event("export_runs", %{"format" => format}, socket) do
    runs = socket.assigns.runs

    {content, filename, content_type} =
      case format do
        "csv" ->
          csv =
            [
              "id,workspace,workflow,status,phases,execution_type,total_tokens,total_cost_usd\n"
              | Enum.map(runs, fn r ->
                  "#{r.id},#{run_workspace(r)},#{r.workflow_type},#{r.status},#{run_phase_count(r)},#{Map.get(r, :execution_type, "subscription")},#{Map.get(r, :total_tokens, 0)},#{Map.get(r, :total_cost_usd, 0.0)}\n"
                end)
            ]
            |> IO.iodata_to_binary()

          {csv, "runs-#{Date.to_iso8601(Date.utc_today())}.csv", "text/csv"}

        _ ->
          json =
            Enum.map(runs, fn r ->
              %{
                id: r.id,
                workspace: run_workspace(r),
                workflow: r.workflow_type,
                status: r.status,
                phases: run_phase_count(r),
                execution_type: Map.get(r, :execution_type, "subscription"),
                total_tokens: Map.get(r, :total_tokens, 0),
                total_cost_usd: Map.get(r, :total_cost_usd, 0.0)
              }
            end)
            |> Jason.encode!(pretty: true)

          {json, "runs-#{Date.to_iso8601(Date.utc_today())}.json", "application/json"}
      end

    {:noreply,
     push_event(socket, "download", %{
       content: content,
       filename: filename,
       content_type: content_type
     })}
  end

  def handle_event("toggle_completed", _params, socket) do
    show_all = !socket.assigns.show_all_completed
    {visible, hidden_count} = visible_completed(socket.assigns.all_completed_runs, show_all)

    {:noreply,
     assign(socket,
       show_all_completed: show_all,
       completed_runs: visible,
       hidden_completed_count: hidden_count
     )}
  end

  defp safe_list_runs do
    rollups =
      safe_call(fn -> TraceReader.list_runs() end, [])
      |> Map.new(&{&1.run_id, &1})

    running =
      safe_call(fn -> Orchestrator.list_runs() end, [])
      |> Enum.map(fn run -> normalize_running_run(run, Map.get(rollups, run.id)) end)

    running_ids = MapSet.new(running, & &1.id)

    db_runs =
      safe_call(
        fn ->
          WorkflowRun
          |> order_by([r], desc: r.updated_at)
          |> limit(200)
          |> Repo.all()
          |> Enum.reject(&MapSet.member?(running_ids, &1.run_id))
          |> Enum.map(&db_run_to_struct(&1, Map.get(rollups, &1.run_id)))
        end,
        []
      )

    known_ids = MapSet.new(running ++ db_runs, & &1.id)

    trace_only_runs =
      rollups
      |> Map.values()
      |> Enum.reject(&MapSet.member?(known_ids, &1.run_id))
      |> Enum.map(&trace_run_to_struct/1)

    (running ++ db_runs ++ trace_only_runs)
    |> Enum.sort_by(&(Map.get(&1, :started_at) || ""), :desc)
  end

  defp db_run_to_struct(row, rollup) do
    status =
      normalize_status(Map.get(rollup || %{}, :status, row.status))

    phases =
      (row.phases || [])
      |> Enum.map(fn p ->
        %{
          id: p["id"] || p["phaseId"] || "p0",
          name: p["name"],
          type: safe_atom(p["type"]),
          status: safe_atom(p["status"] || "pending"),
          retry_count: p["retryCount"] || p["retry_count"] || 0,
          max_retries: p["maxRetries"] || p["max_retries"] || 2,
          depends_on: p["dependsOn"] || p["depends_on"] || []
        }
      end)

    %{
      id: row.run_id,
      workflow_type: row.workflow_name || "unknown",
      workspace_path: row.workspace_path,
      status: status,
      phases: phases,
      phase_count: length(phases),
      started_at: rollup_started_at(rollup, row.created_at),
      duration_ms: Map.get(rollup || %{}, :duration_ms, 0),
      execution_type: row.execution_type || "subscription",
      total_input_tokens: Map.get(rollup || %{}, :total_input_tokens, 0),
      total_output_tokens: Map.get(rollup || %{}, :total_output_tokens, 0),
      total_tokens: Map.get(rollup || %{}, :total_tokens, 0),
      total_cost_usd: Map.get(rollup || %{}, :total_cost_usd, 0.0),
      client_id: row.client_id || Map.get(rollup || %{}, :client_id)
    }
  end

  defp normalize_running_run(run, rollup) do
    phases = Map.get(run, :phases, [])

    %{
      id: Map.get(run, :id),
      workflow_type: Map.get(run, :workflow_type, "unknown"),
      workspace_path: Map.get(run, :workspace_path) || Map.get(rollup || %{}, :workspace_path),
      status: normalize_status(Map.get(rollup || %{}, :status, Map.get(run, :status))),
      phases: phases,
      phase_count: length(phases),
      started_at: rollup_started_at(rollup, Map.get(run, :started_at)),
      duration_ms: Map.get(rollup || %{}, :duration_ms, 0),
      execution_type:
        Map.get(run, :execution_type) || Map.get(rollup || %{}, :execution_type) || "subscription",
      total_input_tokens: Map.get(rollup || %{}, :total_input_tokens, 0),
      total_output_tokens: Map.get(rollup || %{}, :total_output_tokens, 0),
      total_tokens: Map.get(rollup || %{}, :total_tokens, 0),
      total_cost_usd: Map.get(rollup || %{}, :total_cost_usd, 0.0),
      client_id: Map.get(run, :client_id) || Map.get(rollup || %{}, :client_id)
    }
  end

  defp trace_run_to_struct(trace_run) do
    %{
      id: Map.get(trace_run, :run_id),
      workflow_type: Map.get(trace_run, :workflow_name) || Map.get(trace_run, :run_id),
      workspace_path: Map.get(trace_run, :workspace_path),
      status: normalize_status(Map.get(trace_run, :status)),
      phases: [],
      phase_count: Map.get(trace_run, :phase_count, 0),
      started_at: Map.get(trace_run, :started_at),
      duration_ms: Map.get(trace_run, :duration_ms, 0),
      execution_type: Map.get(trace_run, :execution_type) || "subscription",
      total_input_tokens: Map.get(trace_run, :total_input_tokens, 0),
      total_output_tokens: Map.get(trace_run, :total_output_tokens, 0),
      total_tokens: Map.get(trace_run, :total_tokens, 0),
      total_cost_usd: Map.get(trace_run, :total_cost_usd, 0.0),
      client_id: Map.get(trace_run, :client_id)
    }
  end

  defp normalize_status(nil), do: "unknown"
  defp normalize_status(status) when is_atom(status), do: Atom.to_string(status)
  defp normalize_status(status) when is_binary(status), do: status
  defp normalize_status(_), do: "unknown"

  defp rollup_started_at(%{started_at: started_at}, _fallback), do: started_at
  defp rollup_started_at(_, %DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp rollup_started_at(_, %NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp rollup_started_at(_, started_at) when is_binary(started_at), do: started_at
  defp rollup_started_at(_, _), do: nil

  defp safe_atom(nil), do: :unknown

  defp safe_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> :unknown
  end

  defp safe_atom(a) when is_atom(a), do: a
  defp safe_atom(_), do: :unknown

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(other), do: other

  # ---------------------------------------------------------------------------
  # Run partitioning (active vs completed with TTL)
  # ---------------------------------------------------------------------------

  defp assign_partitioned_runs(socket, runs) do
    {active, all_completed} = Enum.split_with(runs, &(normalize_status(&1.status) not in @terminal_statuses))
    show_all = socket.assigns.show_all_completed
    {visible, hidden_count} = visible_completed(all_completed, show_all)

    assign(socket,
      active_runs: active,
      all_completed_runs: all_completed,
      completed_runs: visible,
      hidden_completed_count: hidden_count
    )
  end

  defp visible_completed(all_completed, true = _show_all), do: {all_completed, 0}

  defp visible_completed(all_completed, false = _show_all) do
    cutoff = DateTime.utc_now() |> DateTime.add(-@completed_ttl_ms, :millisecond)

    recent =
      Enum.filter(all_completed, fn run ->
        case parse_started_at(run.started_at) do
          {:ok, dt} -> DateTime.compare(dt, cutoff) != :lt
          :error -> true
        end
      end)

    {recent, length(all_completed) - length(recent)}
  end

  defp parse_started_at(nil), do: :error
  defp parse_started_at(%DateTime{} = dt), do: {:ok, dt}

  defp parse_started_at(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_started_at(_), do: :error

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @doc "Renders the runs dashboard with sidebar, detail pane, and scope filters."
  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <div class="flex items-center justify-between gap-4">
          <.scope_filter_bar
            event="set_scope_filters"
            client_filter={@client_filter}
            workspace_filter={@workspace_filter}
            client_options={@client_options}
            workspace_options={@workspace_options}
          />
          <div class="mb-4 flex justify-end">
            <.last_updated at={@last_updated_at} />
          </div>
        </div>

        <%!-- DETAIL VIEW --%>
        <div :if={@selected} class="grid grid-cols-12 gap-6">
          <%!-- LEFT: Run list sidebar --%>
          <div class="col-span-12 lg:col-span-4 space-y-6">
            <.run_list_sidebar
              active_runs={@active_runs}
              completed_runs={@completed_runs}
              all_completed_runs={@all_completed_runs}
              hidden_completed_count={@hidden_completed_count}
              show_all_completed={@show_all_completed}
              selected={@selected}
              client_filter={@client_filter}
              workspace_filter={@workspace_filter}
            />
          </div>

          <%!-- RIGHT: Detail panel --%>
          <div class="col-span-12 lg:col-span-8 space-y-6">
            <%!-- Header HUD --%>
            <div class="bg-surface-container-low border-t-2 border-[#ffa44c] p-6 relative overflow-hidden">
              <span class="material-symbols-outlined text-[100px] text-[#ffa44c]/5 absolute -right-4 -top-4 select-none">memory</span>
              <div class="flex flex-wrap items-center justify-between gap-6 mb-8 relative z-10">
                <div>
                  <div class="flex items-center gap-3 mb-1">
                    <h1 class="text-3xl font-headline font-black text-white tracking-tighter uppercase">
                      RUN_LOG: {String.slice(@selected.id, 0, 12)}
                    </h1>
                    <.status_badge status={@selected.status} />
                  </div>
                  <p class="font-label text-xs text-[#ffa44c]/60 tracking-[0.2em]">
                    {String.upcase(@selected.workflow_type)}
                    <span :if={@selected.started_at}> // {format_time(@selected.started_at)}</span>
                  </p>
                </div>
                <div class="flex gap-8 border-l border-white/10 pl-8">
                  <div class="text-center">
                    <p class="text-[10px] font-label text-white/50 mb-1 uppercase tracking-widest">EXECUTION</p>
                    <p class="text-xl font-headline font-bold text-[#00eefc] tracking-tighter">{format_duration_ms(@selected.duration_ms)}</p>
                  </div>
                  <div class="text-center">
                    <p class="text-[10px] font-label text-white/50 mb-1 uppercase tracking-widest">UNIT_COST</p>
                    <p class="text-xl font-headline font-bold text-white tracking-tighter">
                      {if @selected.execution_type == "subscription", do: "\u2014", else: "$#{format_usd(@selected.total_cost_usd || 0.0)}"}
                    </p>
                  </div>
                  <div class="text-center">
                    <p class="text-[10px] font-label text-white/50 mb-1 uppercase tracking-widest">TOTAL_TOKENS</p>
                    <p class="text-xl font-headline font-bold text-white tracking-tighter">{format_tokens(@selected.total_tokens || 0)}</p>
                  </div>
                </div>
              </div>

              <%!-- Phase progression bar --%>
              <div :if={@selected.phases != []} class="space-y-2">
                <div class="flex justify-between font-label text-[9px] text-[#ffa44c] tracking-widest">
                  <span>PHASE_SEQUENCING</span>
                  <span>{phase_completion_pct(@selected.phases)}% NOMINAL</span>
                </div>
                <div class={"grid grid-cols-#{max(length(@selected.phases), 1)} gap-1 h-3"}>
                  <div
                    :for={phase <- @selected.phases}
                    class={phase_bar_class(phase.status)}
                  />
                </div>
              </div>

              <.link
                patch={runs_path(nil, @client_filter, @workspace_filter)}
                class="absolute top-4 right-4 text-[10px] font-label text-[#00eefc] border border-[#00eefc]/30 px-3 py-1 hover:bg-[#00eefc]/10 z-10"
              >
                BACK_TO_LIST
              </.link>
            </div>

            <%!-- Phase cards horizontal scroll --%>
            <div :if={@selected.phases != []} class="flex gap-4 overflow-x-auto pb-4">
              <div
                :for={phase <- @selected.phases}
                class={[
                  "flex-shrink-0 w-48 bg-surface-container-low p-4",
                  phase_card_border(phase.status)
                ]}
              >
                <p class="font-label text-[9px] text-[#00eefc] tracking-widest mb-1">{String.upcase(to_string(phase.type))}</p>
                <h5 class="font-headline font-bold text-xs uppercase mb-3">{phase.name || phase.id}</h5>
                <div class="space-y-1.5 font-label text-[10px]">
                  <div class="flex justify-between">
                    <span class="text-white/50">STATUS</span>
                    <span class={phase_status_color(phase.status)}>{String.upcase(to_string(phase.status))}</span>
                  </div>
                  <div class="flex justify-between">
                    <span class="text-white/50">RETRY</span>
                    <span class="text-white">{String.pad_leading(to_string(phase.retry_count), 2, "0")}/{String.pad_leading(to_string(phase.max_retries), 2, "0")}</span>
                  </div>
                  <div class="flex justify-between">
                    <span class="text-white/50">DURATION</span>
                    <.phase_duration events={@trace_events} phase_id={phase.id} />
                  </div>
                </div>
              </div>
            </div>

            <%!-- Tabs --%>
            <div class="bg-surface-container-low border border-white/5">
              <div class="flex border-b border-white/5">
                <button
                  :for={{tab_id, tab_label} <- [{"timeline", "Timeline_Log"}, {"session", "Session_Output"}]}
                  class={[
                    "px-8 py-4 font-headline font-bold text-xs tracking-[0.2em] uppercase",
                    if(@active_tab == tab_id,
                      do: "border-b-2 border-[#ffa44c] bg-[#ffa44c]/5 text-[#ffa44c]",
                      else: "text-white/40 hover:text-white transition-colors")
                  ]}
                  phx-click="switch_tab"
                  phx-value-tab={tab_id}
                >
                  {tab_label}
                </button>
              </div>

              <div class="p-6">
                <%!-- Timeline tab --%>
                <div :if={@active_tab == "timeline"}>
                  <div :if={@trace_events == []} class="text-center py-8">
                    <span class="material-symbols-outlined text-4xl text-[#ffa44c]/20">schedule</span>
                    <p class="text-[10px] font-label text-white/30 mt-2">NO_TRACE_EVENTS_RECORDED</p>
                  </div>

                  <div
                    :if={@trace_events != []}
                    class="max-h-[600px] overflow-y-auto space-y-6"
                    id="trace-timeline"
                  >
                    <div :for={event <- @trace_events} class="flex gap-6 relative">
                      <div class="w-24 text-[10px] font-label text-white/50 text-right pt-1">
                        {format_time(event["timestamp"])}
                      </div>
                      <div class="flex-shrink-0 w-3 h-3 border-2 border-[#ffa44c] rounded-full mt-1.5 bg-black relative z-10"></div>
                      <div class="flex-1 pb-6 border-l border-white/10 ml-[-1.125rem] pl-8">
                        <div class="flex items-center gap-3 mb-2">
                          <span class="text-xs font-bold font-headline uppercase text-white">{event["eventType"]}</span>
                          <span
                            :if={event["tool"]}
                            class="bg-[#00eefc]/10 text-[#00eefc] text-[8px] font-label px-1 border border-[#00eefc]/20"
                          >
                            {event["tool"]}
                          </span>
                        </div>
                        <p :if={event["detail"]} class="text-xs text-white/60 font-label leading-relaxed">
                          {event["detail"]}
                        </p>
                      </div>
                    </div>
                  </div>
                </div>

                <%!-- Session output tab --%>
                <div :if={@active_tab == "session"}>
                  <div class="flex flex-wrap gap-2 mb-4">
                    <%= for phase <- Enum.filter(@selected.phases, &(&1.type in [:session, :team, :review_gate, :pr_shepherd, :preflight])) do %>
                      <button
                        phx-click="view_session_log"
                        phx-value-phase-id={phase.id}
                        class={[
                          "px-4 py-2 font-label text-[10px] uppercase tracking-widest border transition-all",
                          if(@session_log_phase == phase.id,
                            do: "bg-[#ffa44c]/10 border-[#ffa44c]/40 text-[#ffa44c]",
                            else: "border-white/10 text-white/40 hover:text-white hover:border-white/30")
                        ]}
                      >
                        {phase.name || phase.id}
                      </button>
                    <% end %>
                  </div>

                  <div
                    :if={@session_log}
                    class="bg-black p-4 max-h-[500px] overflow-y-auto border border-white/5"
                  >
                    <pre class="text-xs font-label whitespace-pre-wrap break-words text-white/80"><%= @session_log %></pre>
                  </div>

                  <div :if={!@session_log} class="text-center py-8">
                    <span class="material-symbols-outlined text-4xl text-[#ffa44c]/20">description</span>
                    <p class="text-[10px] font-label text-white/30 mt-2">SELECT_PHASE_TO_VIEW_OUTPUT</p>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- LIST VIEW --%>
        <div :if={!@selected} id="runs-list" phx-hook="Download">
          <div :if={@runs != []} class="flex justify-end gap-2 mb-4">
            <button
              :for={{fmt, icon} <- [{"csv", "table_view"}, {"json", "data_object"}]}
              phx-click="export_runs"
              phx-value-format={fmt}
              class="text-[10px] font-label text-[#00eefc] border border-[#00eefc]/30 px-3 py-1 hover:bg-[#00eefc]/10 flex items-center gap-1"
            >
              <span class="material-symbols-outlined text-xs">{icon}</span> {String.upcase(fmt)}
            </button>
          </div>

          <div :if={@runs == []} class="text-center py-12">
            <span class="material-symbols-outlined text-6xl text-[#ffa44c]/20">play_circle</span>
            <p class="text-[10px] font-label text-white/30 mt-3">NO_WORKFLOW_RUNS_DETECTED</p>
          </div>

          <%!-- Active runs --%>
          <div :if={@active_runs != []} id="active-runs" class="mb-8">
            <.hud_card accent="secondary">
              <.hud_header icon="sensors" label={"ACTIVE_PROTOCOLS [#{length(@active_runs)}]"}>
                <:actions>
                  <span class="bg-[#00eefc]/10 text-[#00eefc] text-[10px] font-label px-2 py-0.5 border border-[#00eefc]/20">LIVE_SYNC</span>
                </:actions>
              </.hud_header>
              <.runs_table
                runs={@active_runs}
                client_filter={@client_filter}
                workspace_filter={@workspace_filter}
                muted={false}
              />
            </.hud_card>
          </div>

          <%!-- Completed runs --%>
          <div :if={@all_completed_runs != []} id="completed-runs">
            <.hud_card>
              <.hud_header icon="inventory_2" label={"COMPLETED_RUNS [#{length(@completed_runs)}]"}>
                <:actions>
                  <span
                    :if={@hidden_completed_count > 0 and not @show_all_completed}
                    class="text-[10px] font-label text-white/30 mr-2"
                  >
                    +{@hidden_completed_count} HIDDEN
                  </span>
                  <button
                    phx-click="toggle_completed"
                    class="text-[10px] font-label text-[#00eefc] border border-[#00eefc]/30 px-3 py-1 hover:bg-[#00eefc]/10"
                  >
                    {if @show_all_completed, do: "SHOW_RECENT", else: "SHOW_ALL"}
                  </button>
                </:actions>
              </.hud_header>
              <.runs_table
                runs={@completed_runs}
                client_filter={@client_filter}
                workspace_filter={@workspace_filter}
                muted={true}
              />
            </.hud_card>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Helper components
  # ---------------------------------------------------------------------------

  attr :runs, :list, required: true
  attr :client_filter, :string, required: true
  attr :workspace_filter, :string, required: true
  attr :muted, :boolean, default: false

  defp runs_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="w-full text-left font-label">
        <thead>
          <tr class="bg-surface-container-high/50 text-[10px] text-white/40 uppercase tracking-widest">
            <th class="px-4 py-3 font-normal">RUN_ID</th>
            <th class="px-4 py-3 font-normal">WORKSPACE / WORKFLOW</th>
            <th class="px-4 py-3 font-normal">CLIENT</th>
            <th class="px-4 py-3 font-normal">STATUS</th>
            <th class="px-4 py-3 font-normal">PHASES</th>
            <th class="px-4 py-3 font-normal">TOKENS</th>
            <th class="px-4 py-3 font-normal text-right">COST</th>
            <th class="px-4 py-3 font-normal"></th>
          </tr>
        </thead>
        <tbody class="text-xs divide-y divide-white/5">
          <tr
            :for={run <- @runs}
            class={["hover:bg-white/5 transition-colors cursor-pointer", @muted && "opacity-60"]}
          >
            <td class="px-4 py-3">
              <.link
                patch={runs_path(run.id, @client_filter, @workspace_filter)}
                class="text-[#00eefc] hover:text-[#00eefc]/80 font-label"
                title={run.id}
              >
                #{String.slice(run.id, 0, 12)}
              </.link>
            </td>
            <td class="px-4 py-3">
              <div class="font-label text-[10px] text-white/40 truncate max-w-xs" title={run_workspace(run)}>
                {run_workspace(run)}
              </div>
              <div class="text-white/80 uppercase">{run.workflow_type}</div>
            </td>
            <td class="px-4 py-3 font-label text-white/50">{run.client_id || "\u2014"}</td>
            <td class="px-4 py-3"><.status_badge status={run.status} /></td>
            <td class="px-4 py-3 text-white/60">{run_phase_count(run)}</td>
            <td class="px-4 py-3 text-white/60">{format_tokens(run.total_tokens || 0)}</td>
            <td class={["px-4 py-3 text-right", if(run.execution_type == "subscription", do: "text-white/30", else: "text-[#ffa44c]")]}>
              {if run.execution_type == "subscription", do: "\u2014", else: "$#{format_usd(run.total_cost_usd || 0.0)}"}
            </td>
            <td class="px-4 py-3">
              <button
                :if={run_cancellable?(run.status)}
                phx-click="cancel_run"
                phx-value-id={run.id}
                class="text-[#ff725e] text-[9px] font-label border border-[#ff725e]/30 px-2 py-0.5 hover:bg-[#ff725e]/10"
              >
                CANCEL
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # --- Run list sidebar for detail view ---

  attr :active_runs, :list, required: true
  attr :completed_runs, :list, required: true
  attr :all_completed_runs, :list, required: true
  attr :hidden_completed_count, :integer, required: true
  attr :show_all_completed, :boolean, required: true
  attr :selected, :map, required: true
  attr :client_filter, :string, required: true
  attr :workspace_filter, :string, required: true

  defp run_list_sidebar(assigns) do
    all_runs = assigns.active_runs ++ assigns.completed_runs

    assigns = assign(assigns, :all_runs, all_runs)

    ~H"""
    <section class="bg-surface-container-low p-1 border-l-4 border-[#00eefc] shadow-[0_0_20px_rgba(0,238,252,0.15)]">
      <div class="bg-black p-4 border border-white/5">
        <div class="flex justify-between items-start mb-6">
          <h2 class="font-headline font-bold text-xl text-[#00eefc] tracking-tight">ACTIVE_PROTOCOLS</h2>
          <span class="bg-[#00eefc]/10 text-[#00eefc] text-[10px] font-label px-2 py-0.5 border border-[#00eefc]/20">LIVE_SYNC</span>
        </div>
        <div class="space-y-3 max-h-[600px] overflow-y-auto">
          <.link
            :for={run <- @all_runs}
            patch={runs_path(run.id, @client_filter, @workspace_filter)}
            class={[
              "block p-4 border transition-colors cursor-pointer",
              run_sidebar_class(run, @selected)
            ]}
          >
            <div class="flex justify-between items-start mb-2">
              <span class="font-label text-[10px] text-white/40">RUN_ID: {String.slice(run.id, 0, 12)}</span>
              <span class={["text-[10px] font-bold font-label", run_status_color(run.status)]}>
                {String.upcase(normalize_status(run.status))}
              </span>
            </div>
            <h4 class="font-headline text-sm font-bold text-white/80 mb-1 uppercase truncate">{run.workflow_type}</h4>
            <div class="flex justify-between items-end mt-4">
              <div class="text-[9px] font-label text-white/40 space-y-0.5">
                <p>PHASES: {run_phase_count(run)}</p>
                <p>TOKENS: {format_tokens(run.total_tokens || 0)}</p>
              </div>
              <div class="text-[12px] font-label text-white/60">{format_duration_ms(run.duration_ms)}</div>
            </div>
          </.link>
        </div>
        <button
          :if={@hidden_completed_count > 0}
          phx-click="toggle_completed"
          class="w-full mt-6 py-2 border border-white/10 font-label text-[10px] text-white/40 hover:bg-surface-container-high transition-all tracking-[0.2em] uppercase"
        >
          {if @show_all_completed, do: "SHOW_RECENT", else: "VIEW_ALL_LOGS (+#{@hidden_completed_count})"}
        </button>
      </div>
    </section>
    """
  end

  defp run_sidebar_class(run, selected) do
    is_selected = selected && selected.id == run.id
    status = normalize_status(run.status)

    cond do
      is_selected && status in ["running", "in_progress"] ->
        "bg-surface-container-high border-[#00eefc]/30 relative overflow-hidden"

      is_selected ->
        "bg-surface-container-high border-[#ffa44c]/30"

      status in ["running", "in_progress"] ->
        "bg-surface-container-low border-[#00eefc]/10 hover:border-[#00eefc]"

      status == "failed" ->
        "bg-surface-container-low border-white/5 hover:border-[#ff725e]/50"

      true ->
        "bg-surface-container-low border-white/5 hover:border-[#ffa44c]/50"
    end
  end

  defp run_status_color(status) do
    case normalize_status(status) do
      s when s in ["running", "in_progress"] -> "text-[#00eefc]"
      s when s in ["done", "completed"] -> "text-[#ffa44c]"
      "failed" -> "text-[#ff725e]"
      "pending" -> "text-[#ffa44c]/60"
      _ -> "text-white/40"
    end
  end

  defp phase_completion_pct(phases) when is_list(phases) do
    total = length(phases)
    if total == 0, do: 0, else: round(Enum.count(phases, &(to_string(&1.status) in ["done", "completed"])) / total * 100)
  end

  defp phase_bar_class(status) do
    case to_string(status) do
      s when s in ["done", "completed"] -> "bg-[#ffa44c] shadow-[0_0_8px_rgba(255,164,76,0.5)]"
      s when s in ["running", "in_progress"] -> "bg-[#00eefc] shadow-[0_0_8px_rgba(0,238,252,0.5)] animate-pulse"
      "failed" -> "bg-[#ff725e] shadow-[0_0_8px_rgba(255,114,94,0.5)]"
      _ -> "bg-surface-container-high"
    end
  end

  defp phase_card_border(status) do
    case to_string(status) do
      s when s in ["done", "completed"] -> "border-l-2 border-l-[#00eefc]"
      s when s in ["running", "in_progress"] -> "border-l-2 border-l-[#00eefc]"
      "failed" -> "border-l-2 border-l-[#ff725e]"
      _ -> "border-l-2 border-l-white/10 opacity-50"
    end
  end

  defp phase_status_color(status) do
    case to_string(status) do
      s when s in ["done", "completed"] -> "text-[#ffa44c]"
      s when s in ["running", "in_progress"] -> "text-[#00eefc]"
      "failed" -> "text-[#ff725e]"
      _ -> "text-white/40"
    end
  end

  defp apply_scope_filters(runs, client_filter, workspace_filter) do
    Enum.filter(runs, fn run ->
      ScopeFilters.matches_client?(Map.get(run, :client_id), client_filter) and
        ScopeFilters.matches_workspace?(run_workspace(run), workspace_filter)
    end)
  end

  defp build_client_options(runs) do
    runs
    |> Enum.map(&Map.get(&1, :client_id))
    |> ScopeFilters.client_options()
  end

  defp build_workspace_options(runs) do
    runs
    |> Enum.map(&run_workspace/1)
    |> ScopeFilters.workspace_options()
  end

  defp run_workspace(run) do
    Map.get(run, :workspace_path)
  end

  defp runs_path(nil, client_filter, workspace_filter) do
    query =
      %{}
      |> ScopeFilters.apply_scope_query(client_filter, workspace_filter)

    "/runs" <> encode_query(query)
  end

  defp runs_path(id, client_filter, workspace_filter) do
    query =
      %{}
      |> ScopeFilters.apply_scope_query(client_filter, workspace_filter)

    "/runs/#{id}" <> encode_query(query)
  end

  defp encode_query(query) when map_size(query) == 0, do: ""
  defp encode_query(query), do: "?" <> URI.encode_query(query)

  defp run_phase_count(run) do
    case Map.get(run, :phase_count) do
      count when is_integer(count) and count >= 0 -> count
      _ -> length(Map.get(run, :phases, []))
    end
  end

  defp run_cancellable?(status) do
    normalize_status(status) in ["pending", "running", "in_progress"]
  end

  # Expire DB runs stuck as pending/running for >2h with no active RunServer.
  # Prevents ghost entries from accumulating when upserts fail or processes crash.
  @stale_run_threshold_ms 2 * 60 * 60 * 1_000
  defp expire_stale_runs do
    import Ecto.Query
    cutoff = DateTime.utc_now() |> DateTime.add(-@stale_run_threshold_ms, :millisecond)

    {count, _} =
      Crucible.Repo.update_all(
        from(r in "workflow_runs",
          where: r.status in ["pending", "running"] and r.updated_at < ^cutoff
        ),
        set: [status: "cancelled", updated_at: DateTime.utc_now()]
      )

    if count > 0 do
      Logger.info("RunsLive: expired #{count} stale runs stuck as pending/running")
    end
  rescue
    _ -> :ok
  end

  defp format_usd(value) when is_number(value),
    do: (value * 1.0) |> Float.round(2) |> :erlang.float_to_binary(decimals: 2)

  defp format_usd(_), do: "0.00"

  attr :events, :list, required: true
  attr :phase_id, :string, required: true

  defp phase_duration(assigns) do
    token_event =
      Enum.find(assigns.events, fn e ->
        e["eventType"] == "token_efficiency" and e["phaseId"] == assigns.phase_id
      end)

    duration_ms =
      if token_event do
        get_in(token_event, ["metadata", "duration_ms"])
      else
        start_ev =
          Enum.find(
            assigns.events,
            &(&1["eventType"] == "phase_start" and &1["phaseId"] == assigns.phase_id)
          )

        end_ev =
          Enum.find(
            assigns.events,
            &(&1["eventType"] == "phase_end" and &1["phaseId"] == assigns.phase_id)
          )

        if start_ev && end_ev do
          with {:ok, s, _} <- DateTime.from_iso8601(start_ev["timestamp"]),
               {:ok, e, _} <- DateTime.from_iso8601(end_ev["timestamp"]) do
            DateTime.diff(e, s, :millisecond)
          else
            _ -> nil
          end
        end
      end

    assigns = assign(assigns, :duration_ms, duration_ms)

    ~H"""
    <span :if={@duration_ms} class="text-[10px] font-label text-white">
      {format_duration_ms(@duration_ms)}
    </span>
    <span :if={!@duration_ms} class="text-[10px] font-label text-white/30">--</span>
    """
  end
end
