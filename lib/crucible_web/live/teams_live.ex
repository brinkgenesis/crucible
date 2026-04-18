defmodule CrucibleWeb.TeamsLive do
  @moduledoc """
  LiveView for the Activity Monitor dashboard.

  Serves two views depending on route params:

  - **Index** (`/teams`) — lists all active Claude Code sessions with real-time
    tool counts, token usage, and expandable event logs. Sessions are discovered
    from cost events (DB + JSONL) and live process scanning via `SessionDiscovery`.
    Filters by client, workspace, and codebase.

  - **Detail** (`/teams/:name`) — shows a single Agent Team's task board, member
    roster, and live activity feed. Subscribes to PubSub updates from the team
    and refreshes on a faster interval (5s vs 10s).

  Real-time features:
  - Periodic refresh via `Process.send_after/3`
  - PubSub subscription for team updates and session tool events
  - `TranscriptTailer` integration for streaming tool call logs
  - Markdown export of team snapshots
  """

  use CrucibleWeb, :live_view

  alias Crucible.{CostEventReader, Events, SessionDiscovery, TeamReader, TraceReader, TranscriptTailer}
  alias CrucibleWeb.Live.ScopeFilters
  require Logger

  @refresh_interval 10_000
  @detail_refresh_interval 5_000

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Initializes socket assigns with default filter values and empty state.

  When connected, starts the periodic refresh timer and enables `:trap_exit`
  so the process can clean up `TranscriptTailer` watches on termination.
  """
  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      schedule_refresh(@refresh_interval)
      # Clean up TranscriptTailer watches when LiveView terminates
      Process.flag(:trap_exit, true)
    end

    {:ok,
     assign(socket,
       page_title: "Activity",
       current_path: "/teams",
       client_filter: ScopeFilters.all_scope(),
       workspace_filter: ScopeFilters.all_scope(),
       codebase_filter: ScopeFilters.all_scope(),
       client_options: ScopeFilters.client_options([]),
       workspace_options: ScopeFilters.workspace_options([]),
       codebase_options: [%{value: "all", label: "All Codebases"}],
       team: nil,
       team_name: nil,
       subscribed_team: nil,
       team_events: [],
       active_sessions: [],
       expanded_session: nil,
       expanded_events: []
     )}
  end

  @doc """
  Handles route params for both index and detail views.

  When a `"name"` param is present, loads the team detail view: fetches the
  team snapshot via `TeamReader`, subscribes to its PubSub topic, and clears
  stale events when switching teams.

  Without a `"name"` param, loads the index view: discovers active sessions,
  builds codebase filter options, and applies scope filters.
  """
  @impl true
  def handle_params(%{"name" => name} = params, _uri, socket) do
    client_filter = ScopeFilters.normalize_param(params["client_id"])
    workspace_filter = ScopeFilters.normalize_param(params["workspace"])

    team = safe_call(fn -> TeamReader.get_team(name) end, nil)
    socket = maybe_subscribe_team(socket, name)

    # Clear event feed when switching to a different team
    team_events =
      if socket.assigns.team_name == name, do: socket.assigns.team_events, else: []

    {:noreply,
     assign(socket,
       live_params: params,
       team: team,
       team_name: name,
       client_filter: client_filter,
       workspace_filter: workspace_filter,
       team_events: team_events,
       current_path: teams_show_path(name, client_filter, workspace_filter),
       page_title: if(team, do: "Team: #{name}", else: "Activity")
     )}
  end

  def handle_params(params, _uri, socket) do
    client_filter = ScopeFilters.normalize_param(params["client_id"])
    workspace_filter = ScopeFilters.normalize_param(params["workspace"])
    codebase_filter = ScopeFilters.normalize_param(params["codebase"])
    {client_options, workspace_options} = load_scope_options()
    socket = maybe_unsubscribe_team(socket)

    sessions = load_active_sessions(client_filter, workspace_filter)
    codebase_options = build_codebase_options(sessions)
    filtered_sessions = filter_by_codebase(sessions, codebase_filter)

    {:noreply,
     assign(socket,
       live_params: params,
       team: nil,
       team_name: nil,
       client_filter: client_filter,
       workspace_filter: workspace_filter,
       codebase_filter: codebase_filter,
       client_options: client_options,
       workspace_options: workspace_options,
       codebase_options: codebase_options,
       current_path: teams_index_path(client_filter, workspace_filter, codebase_filter),
       active_sessions: filtered_sessions
     )}
  end

  @doc """
  Handles periodic refresh, real-time PubSub events, and team lifecycle messages.

  - `:refresh` — re-fetches team data or active sessions depending on current view,
    then reschedules at the appropriate interval.
  - `{:new_tool_events, session_id, events}` — appends streaming tool events from
    `TranscriptTailer` to the expanded session's event log (capped at 200).
  - `{:team_update, name, snapshot}` / `{:team_completed, name, snapshot}` — appends
    activity feed entries and triggers an immediate refresh.
  """
  @impl true
  def handle_info(:refresh, socket) do
    interval =
      if socket.assigns.team_name, do: @detail_refresh_interval, else: @refresh_interval

    schedule_refresh(interval)

    if socket.assigns.team_name do
      team =
        safe_call(
          fn -> TeamReader.get_team(socket.assigns.team_name) end,
          socket.assigns.team
        )

      {:noreply, assign(socket, team: team)}
    else
      sessions =
        load_active_sessions(socket.assigns.client_filter, socket.assigns.workspace_filter)

      codebase_options = build_codebase_options(sessions)
      filtered = filter_by_codebase(sessions, socket.assigns.codebase_filter)

      {:noreply, assign(socket, active_sessions: filtered, codebase_options: codebase_options)}
    end
  end

  # Real-time tool events pushed from TranscriptTailer via PubSub
  def handle_info({:new_tool_events, session_id, new_events}, socket) do
    if socket.assigns.expanded_session == session_id do
      # Prepend new events (newest first), cap at 200
      updated = new_events ++ socket.assigns.expanded_events
      {:noreply, assign(socket, expanded_events: Enum.take(updated, 200))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:team_update, name, snapshot}, socket) do
    socket = maybe_append_event(socket, name, :update, snapshot)
    send(self(), :refresh)
    {:noreply, socket}
  end

  def handle_info({:team_completed, name, snapshot}, socket) do
    socket = maybe_append_event(socket, name, :completed, snapshot)
    send(self(), :refresh)
    {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @doc """
  Handles UI events from the browser.

  - `"toggle_session"` — expands or collapses a session's tool event log. On expand,
    starts a `TranscriptTailer` watch and subscribes to PubSub for real-time pushes.
    Falls back to direct transcript reads if the tailer is unavailable.
  - `"export_team"` — generates a Markdown export of the current team via
    `TeamReader.export_markdown/1` and pushes a browser download event.
  - `"set_scope_filters"` — applies client/workspace/codebase filter changes by
    patching the URL with updated query params.
  """
  @impl true
  def handle_event("toggle_session", %{"id" => session_id}, socket) do
    prev = socket.assigns.expanded_session

    # Unsubscribe from previous session
    if prev do
      Phoenix.PubSub.unsubscribe(Crucible.PubSub, "session_events:#{prev}")
    end

    if prev == session_id do
      {:noreply, assign(socket, expanded_session: nil, expanded_events: [])}
    else
      # Start tailing and subscribe for real-time pushes
      try do
        TranscriptTailer.watch(session_id)
      catch
        :exit, _ -> Logger.warning("TranscriptTailer not available, using direct read")
      end

      Phoenix.PubSub.subscribe(Crucible.PubSub, "session_events:#{session_id}")

      # Load existing buffered events from tailer, fall back to direct transcript read
      events =
        try do
          case TranscriptTailer.events(session_id, 100) do
            [] -> load_session_events(session_id)
            buffered -> buffered
          end
        catch
          :exit, _ -> load_session_events(session_id)
        end

      {:noreply, assign(socket, expanded_session: session_id, expanded_events: events)}
    end
  end

  def handle_event("export_team", _params, socket) do
    name = socket.assigns.team_name

    case TeamReader.export_markdown(name) do
      content when is_binary(content) ->
        {:noreply,
         push_event(socket, "download", %{
           content: content,
           filename: "#{name}-export.md",
           content_type: "text/markdown"
         })}

      nil ->
        {:noreply, put_flash(socket, :error, "Team not found")}
    end
  end

  def handle_event("set_scope_filters", params, socket) do
    client_filter = ScopeFilters.normalize_param(params["client_id"])
    workspace_filter = ScopeFilters.normalize_param(params["workspace"])
    codebase_filter = ScopeFilters.normalize_param(params["codebase"])
    {:noreply, push_patch(socket, to: teams_index_path(client_filter, workspace_filter, codebase_filter))}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @doc """
  Renders either the team detail view or the session activity index.

  Delegates to `detail_view/1` when a team is loaded, or `session_activity/1`
  for the index listing. Both are wrapped in the shared app layout.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <.detail_view
          :if={@team}
          team={@team}
          team_name={@team_name}
          team_events={@team_events}
          client_filter={@client_filter}
          workspace_filter={@workspace_filter}
        />
        <.session_activity
          :if={!@team}
          sessions={@active_sessions}
          expanded={@expanded_session}
          expanded_events={@expanded_events}
          client_filter={@client_filter}
          workspace_filter={@workspace_filter}
          codebase_filter={@codebase_filter}
          client_options={@client_options}
          workspace_options={@workspace_options}
          codebase_options={@codebase_options}
        />
      </div>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Session Activity Feed
  # ---------------------------------------------------------------------------

  attr :sessions, :list, required: true
  attr :expanded, :string, default: nil
  attr :expanded_events, :list, default: []
  attr :client_filter, :string, required: true
  attr :workspace_filter, :string, required: true
  attr :codebase_filter, :string, default: "all"
  attr :client_options, :list, required: true
  attr :codebase_options, :list, default: []
  attr :workspace_options, :list, required: true

  defp session_activity(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Page header --%>
      <div class="flex justify-between items-end border-b-2 border-[#ffa44c]/20 pb-3">
        <div>
          <h1 class="text-3xl font-headline font-bold text-[#ffa44c] tracking-tighter uppercase">
            ACTIVITY_MONITOR
          </h1>
          <p class="font-mono text-xs text-[#00eefc] opacity-70">
            ACTIVE_SESSIONS // REALTIME_AGENT_TRACKING
          </p>
        </div>
      </div>

      <form phx-change="set_scope_filters" class="flex flex-wrap items-end gap-3 bg-surface-container-low hud-border p-3">
        <label class="w-full sm:w-56">
          <span class="text-[10px] font-label tracking-widest text-[#ffa44c]/60 uppercase block mb-1">CLIENT</span>
          <select name="client_id" class="w-full bg-transparent border-b border-[#777575] text-white font-label text-xs py-1 focus:border-[#00eefc] focus:outline-none">
            <option :for={option <- @client_options} value={option.value} selected={option.value == @client_filter}>{option.label}</option>
          </select>
        </label>
        <label class="w-full sm:w-64">
          <span class="text-[10px] font-label tracking-widest text-[#00eefc]/60 uppercase block mb-1">WORKSPACE</span>
          <select name="workspace" class="w-full bg-transparent border-b border-[#777575] text-white font-label text-xs py-1 focus:border-[#00eefc] focus:outline-none">
            <option :for={option <- @workspace_options} value={option.value} selected={option.value == @workspace_filter}>{option.label}</option>
          </select>
        </label>
        <label :if={length(@codebase_options) > 1} class="w-full sm:w-56">
          <span class="text-[10px] font-label tracking-widest text-[#39ff14]/60 uppercase block mb-1">CODEBASE</span>
          <select name="codebase" class="w-full bg-transparent border-b border-[#777575] text-white font-label text-xs py-1 focus:border-[#39ff14] focus:outline-none">
            <option :for={option <- @codebase_options} value={option.value} selected={option.value == @codebase_filter}>{option.label}</option>
          </select>
        </label>
      </form>

      <%!-- Active sessions header --%>
      <div class="flex items-center gap-3">
        <span class="material-symbols-outlined text-[#00eefc]">sensors</span>
        <h2 class="font-headline font-bold text-sm text-[#ffa44c] uppercase tracking-widest">ACTIVE_SESSIONS</h2>
        <span :if={@sessions != []} class="px-2 py-0.5 bg-[#00eefc]/10 text-[#00eefc] text-[8px] font-bold border border-[#00eefc]/20 uppercase">
          {String.pad_leading(to_string(length(@sessions)), 2, "0")} ONLINE
        </span>
      </div>

      <div :if={@sessions == []} class="text-center py-12 text-[#494847]">
        <span class="material-symbols-outlined text-4xl opacity-30">signal_disconnected</span>
        <p class="font-mono text-[10px] mt-2">NO_ACTIVE_SESSIONS_DETECTED</p>
      </div>

      <div :if={@sessions != []} class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
        <.session_card
          :for={s <- @sessions}
          session={s}
          expanded={@expanded == s.session_id}
          events={if @expanded == s.session_id, do: @expanded_events, else: []}
        />
      </div>
    </div>
    """
  end

  attr :session, :map, required: true
  attr :expanded, :boolean, default: false
  attr :events, :list, default: []

  defp session_card(assigns) do

    ~H"""
    <div
      class="bg-surface-container-low border border-[#494847]/15 p-4 hover:bg-surface-container-high transition-colors cursor-pointer group"
      phx-click="toggle_session"
      phx-value-id={@session.session_id}
    >
      <div class="flex items-center justify-between mb-2">
        <div class="flex items-center gap-2">
          <span class={[
            "inline-block w-2 h-2 shrink-0",
            if(session_active?(@session), do: "bg-[#00FF41] animate-pulse", else: "bg-[#494847]")
          ]} />
          <span class="font-mono text-[11px] font-bold text-[#ffa44c] tracking-tighter">{@session.short_id}</span>
          <span :if={Map.get(@session, :execution_type) == "api"} class="px-1.5 py-0.5 bg-[#ffa44c]/10 border border-[#ffa44c]/30 text-[#ffa44c] text-[8px] font-bold">
            API
          </span>
          <span
            :if={Map.get(@session, :execution_type) == "subscription"}
            class="px-1.5 py-0.5 bg-[#00eefc]/10 border border-[#00eefc]/30 text-[#00eefc] text-[8px] font-bold"
          >
            MAX
          </span>
        </div>
        <span class="text-[9px] font-mono text-[#777575]">{session_duration(@session)}</span>
      </div>
      <div :if={workspace_label(@session) != ""} class="text-[10px] text-[#494847] font-mono truncate mb-2" title={Map.get(@session, :workspace_path, "")}>
        {workspace_label(@session)}
      </div>
      <div class="flex items-center gap-3 text-[10px] font-mono text-[#777575]">
        <span>{@session.tool_count} tools</span>
        <span :if={@session.last_tool} class="px-1.5 py-0.5 bg-surface-container-highest text-[9px]">{@session.last_tool}</span>
        <span class="text-[#00eefc]">
          {format_tokens(@session.total_input_tokens + @session.total_output_tokens)} tok
        </span>
      </div>

      <%!-- Expanded event log --%>
      <div
        :if={@expanded && @events != []}
        class="mt-3 pt-3 border-t border-[#494847]/20 max-h-40 overflow-y-auto space-y-1"
      >
        <div :for={ev <- @events} class="flex items-center gap-2 text-[10px] font-mono">
          <span class="text-[#494847] shrink-0">
            {format_event_time_eastern(event_field(ev, :timestamp))}
          </span>
          <span class="px-1.5 py-0.5 bg-surface-container-highest text-[9px]">{event_field(ev, :tool)}</span>
          <span :if={event_field(ev, :detail)} class="text-[#777575] truncate">{event_field(ev, :detail)}</span>
        </div>
      </div>
      <div
        :if={@expanded && @events == []}
        class="mt-3 pt-3 border-t border-[#494847]/20 text-[10px] font-mono text-[#494847]"
      >
        NO_EVENT_DATA_AVAILABLE
      </div>
    </div>
    """
  end

  # Events come as atom-keyed maps (from CostEventReader/Ecto) or string-keyed maps (from transcript)
  defp event_field(ev, key) when is_atom(key) do
    Map.get(ev, key) || Map.get(ev, to_string(key))
  end

  # Convert UTC timestamp to US Eastern (EDT = UTC-4, EST = UTC-5)
  # March-November is EDT (UTC-4)
  @eastern_offset_seconds -4 * 3600

  defp format_event_time_eastern(nil), do: ""
  defp format_event_time_eastern(""), do: ""

  defp format_event_time_eastern(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} ->
        DateTime.add(dt, @eastern_offset_seconds, :second)
        |> Calendar.strftime("%H:%M:%S")

      _ ->
        String.slice(ts, 11, 8)
    end
  end

  defp format_event_time_eastern(%DateTime{} = dt) do
    DateTime.add(dt, @eastern_offset_seconds, :second)
    |> Calendar.strftime("%H:%M:%S")
  end

  defp format_event_time_eastern(%NaiveDateTime{} = ndt) do
    NaiveDateTime.add(ndt, @eastern_offset_seconds, :second)
    |> NaiveDateTime.to_time()
    |> Time.to_string()
    |> String.slice(0, 8)
  end

  defp format_event_time_eastern(_), do: ""

  defp session_active?(session) do
    case DateTime.from_iso8601(session.last_seen || "") do
      {:ok, dt, _} -> DateTime.diff(DateTime.utc_now(), dt) < 300
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Detail view
  # ---------------------------------------------------------------------------

  attr :team, :map, required: true
  attr :team_name, :string, required: true
  attr :team_events, :list, required: true
  attr :client_filter, :string, required: true
  attr :workspace_filter, :string, required: true

  defp detail_view(assigns) do
    pct =
      if assigns.team.task_count > 0,
        do: Float.round(assigns.team.completed / assigns.team.task_count * 100, 0),
        else: 0.0

    in_progress = Enum.filter(assigns.team.tasks, &(&1.status == "in_progress"))
    pending = Enum.filter(assigns.team.tasks, &(&1.status == "pending"))
    completed = Enum.filter(assigns.team.tasks, &(&1.status == "completed"))

    assigns =
      assign(assigns, pct: pct, in_progress: in_progress, pending: pending, completed: completed)

    ~H"""
    <%!-- Header --%>
    <div id="team-detail" phx-hook="Download" class="flex items-center justify-between border-b-2 border-[#ffa44c]/20 pb-3">
      <div class="flex items-center gap-4">
        <.link
          patch={teams_index_path(@client_filter, @workspace_filter)}
          class="text-[#ffa44c] hover:text-[#00eefc] transition-colors"
        >
          <span class="material-symbols-outlined">arrow_back</span>
        </.link>
        <span class={[
          "inline-block w-2.5 h-2.5 shrink-0",
          if(@team.is_active, do: "bg-[#00FF41] animate-pulse", else: "bg-[#494847]")
        ]} />
        <div>
          <h1 class="text-2xl font-headline font-bold text-[#ffa44c] tracking-tighter uppercase truncate max-w-md" title={@team.description || @team_name}>
            {team_display_name(@team)}
          </h1>
          <div class="flex items-center gap-3 mt-1">
            <span class="font-mono text-[10px] text-[#00eefc] opacity-70">{humanize_team_name(@team_name)}</span>
            <span class="font-mono text-[10px] text-[#777575]">{@team.member_count} MEMBERS</span>
          </div>
        </div>
      </div>
      <div class="flex items-center gap-4">
        <button phx-click="export_team" class="px-3 py-1.5 border border-[#ffa44c]/30 text-[#ffa44c] font-mono text-[10px] uppercase tracking-widest hover:border-[#00eefc] hover:text-[#00eefc] transition-colors flex items-center gap-1">
          <span class="material-symbols-outlined text-sm">download</span> EXPORT
        </button>
        <div class="flex items-center gap-2 w-48">
          <div class="flex-1 bg-surface-container-highest h-2 overflow-hidden">
            <div class="bg-[#00FF41] h-full transition-all" style={"width: #{@pct}%"} />
          </div>
          <span class="text-[10px] text-[#777575] font-mono">
            {@team.completed}/{@team.task_count}
          </span>
        </div>
      </div>
    </div>

    <p :if={@team.description} class="text-[10px] font-mono text-[#777575] -mt-2 ml-14">
      {@team_name}
    </p>

    <%!-- Task Board --%>
    <div>
      <.hud_header icon="view_kanban" label="TASK_BOARD" class="mb-4" />
      <div :if={@team.tasks == []} class="text-center py-8 text-[#494847]">
        <span class="material-symbols-outlined text-4xl opacity-30">task_alt</span>
        <p class="font-mono text-[10px] mt-2">NO_TASKS_CREATED</p>
      </div>
      <div :if={@team.tasks != []} class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <.task_column label="IN_PROGRESS" tasks={@in_progress} color="secondary" />
        <.task_column label="PENDING" tasks={@pending} color="primary" />
        <.task_column label="COMPLETED" tasks={@completed} color="success" />
      </div>
    </div>

    <%!-- Members --%>
    <div :if={@team.members != []}>
      <.hud_header icon="group" label="AGENT_ROSTER" class="mb-4" />
      <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
        <.member_panel :for={member <- @team.members} member={member} />
      </div>
    </div>

    <%!-- Activity Feed --%>
    <div :if={@team_events != []}>
      <div class="flex items-center gap-3 mb-4">
        <span class="material-symbols-outlined text-[#00eefc]">bolt</span>
        <h2 class="font-headline font-bold text-sm text-[#ffa44c] uppercase tracking-widest">LIVE_ACTIVITY</h2>
        <span class="px-2 py-0.5 bg-[#00eefc]/10 text-[#00eefc] text-[8px] font-bold border border-[#00eefc]/20">{length(@team_events)}</span>
      </div>
      <div class="space-y-1">
        <div
          :for={ev <- @team_events}
          class="flex items-center gap-3 p-3 bg-surface-container-low border border-[#494847]/10 font-mono text-[11px]"
        >
          <span class={[
            "inline-block w-2 h-2 shrink-0",
            if(ev.type == :completed, do: "bg-[#00FF41]", else: "bg-[#00eefc] animate-pulse")
          ]} />
          <span class="text-[#494847] shrink-0">
            {Calendar.strftime(ev.at, "%H:%M:%S")}
          </span>
          <span :if={ev.type == :completed} class="text-[#00FF41] font-bold">
            ALL_TASKS_COMPLETED
          </span>
          <span :if={ev.type == :update} class="text-white/70">
            UPDATED — {ev.completed}/{ev.task_count} DONE
            <span :if={ev.in_progress > 0} class="text-[#00eefc] ml-1">
              · {ev.in_progress} ACTIVE
            </span>
          </span>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Sub-components
  # ---------------------------------------------------------------------------

  attr :label, :string, required: true
  attr :tasks, :list, required: true
  attr :color, :string, required: true

  defp task_column(assigns) do
    border_color =
      case assigns.color do
        "secondary" -> "border-t-[#00eefc]"
        "success" -> "border-t-[#00FF41]"
        _ -> "border-t-[#ffa44c]"
      end

    assigns = assign(assigns, :border_color, border_color)

    ~H"""
    <div class={"bg-surface-container-low border border-[#494847]/15 border-t-2 " <> @border_color}>
      <div class="p-4">
        <h4 class="text-[10px] font-mono font-bold uppercase tracking-widest text-[#777575] mb-3 flex items-center justify-between">
          {@label}
          <span class="px-1.5 py-0.5 bg-surface-container-highest text-[9px]">{length(@tasks)}</span>
        </h4>
        <div :if={@tasks == []} class="text-[10px] font-mono text-[#494847] py-2">EMPTY</div>
        <div :if={@tasks != []} class="space-y-2">
          <div :for={task <- @tasks} class="p-3 bg-surface-container border border-[#494847]/10 text-sm">
            <div class="flex items-start gap-2">
              <.task_status_dot status={task.status} />
              <div class="flex-1 min-w-0">
                <p class="font-mono text-xs text-white truncate">{task.subject}</p>
                <div class="flex items-center gap-2 mt-1">
                  <span :if={task.owner} class="px-1.5 py-0.5 bg-surface-container-highest text-[9px] font-mono text-[#777575]">
                    @{task.owner}
                  </span>
                  <span :if={task.blocked_by != []} class="text-[10px] font-mono text-[#ff725e]">
                    BLOCKED: {Enum.map_join(task.blocked_by, ", ", &"##{&1}")}
                  </span>
                </div>
              </div>
              <span class="text-[10px] font-mono text-[#494847] shrink-0">#{task.id}</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :member, :map, required: true

  defp member_panel(assigns) do
    ~H"""
    <div class="p-4 bg-surface-container-low border border-[#494847]/15 hover:bg-surface-container-high transition-colors">
      <div class="flex items-center gap-3">
        <.member_status_dot status={@member.status} />
        <span class="font-mono text-xs font-bold text-white">{@member.name}</span>
        <span class={["px-2 py-0.5 text-[9px] font-bold uppercase border", agent_type_hud_class(@member.agent_type)]}>
          {@member.agent_type}
        </span>
        <span class="text-[10px] font-mono text-[#777575] uppercase">{@member.status}</span>
      </div>
      <p :if={@member.current_task} class="text-[10px] font-mono text-[#00eefc] truncate mt-2 pl-5">
        {@member.current_task}
      </p>
    </div>
    """
  end

  attr :status, :string, required: true

  defp task_status_dot(assigns) do
    class =
      case assigns.status do
        "in_progress" -> "bg-[#00eefc] animate-pulse"
        "completed" -> "bg-[#00FF41]"
        _ -> "bg-[#494847]"
      end

    assigns = assign(assigns, :class, class)

    ~H"""
    <span class={["inline-block w-2 h-2 shrink-0 mt-1.5", @class]} />
    """
  end

  attr :status, :string, required: true

  defp member_status_dot(assigns) do
    class =
      case assigns.status do
        "active" -> "bg-[#00FF41] animate-pulse"
        "idle" -> "bg-[#ffa44c]"
        _ -> "bg-[#494847]"
      end

    assigns = assign(assigns, :class, class)

    ~H"""
    <span class={["inline-block w-2 h-2 shrink-0", @class]} />
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp agent_type_hud_class(type) do
    case type do
      t when t in ["coder", "coder-backend", "coder-runtime", "coder-frontend"] ->
        "bg-[#00eefc]/10 border-[#00eefc] text-[#00eefc]"
      "reviewer" -> "bg-[#ffa44c]/10 border-[#ffa44c] text-[#ffa44c]"
      "architect" -> "bg-[#ff725e]/10 border-[#ff725e] text-[#ff725e]"
      "tester" -> "bg-[#00FF41]/10 border-[#00FF41] text-[#00FF41]"
      "team-lead" -> "bg-[#ffa44c]/10 border-[#ffa44c] text-[#ffa44c]"
      _ -> "bg-[#494847]/10 border-[#494847] text-[#494847]"
    end
  end

  defp load_active_sessions(client_filter, workspace_filter) do
    since = DateTime.utc_now() |> DateTime.add(-3600 * 4)
    client_id = ScopeFilters.query_value(client_filter)
    workspace = ScopeFilters.query_value(workspace_filter)

    # Get sessions from cost events (DB + JSONL)
    cost_sessions =
      safe_call(
        fn ->
          CostEventReader.all_sessions(since: since, client_id: client_id, workspace: workspace)
        end,
        []
      )

    known_ids = MapSet.new(cost_sessions, & &1.session_id)

    # Discover live Claude processes that may not have cost events yet
    # (e.g., sessions in other codebases whose cost-tracker writes elsewhere)
    new_procs =
      safe_call(fn -> SessionDiscovery.active_processes() end, [])
      |> Enum.reject(&MapSet.member?(known_ids, &1.session_id))

    # Parallelize transcript token reads — each one scans filesystem
    token_tasks =
      Enum.map(new_procs, fn proc ->
        Task.async(fn ->
          {proc, SessionDiscovery.read_transcript_tokens(proc.session_id)}
        end)
      end)

    token_results =
      try do
        Task.await_many(token_tasks, 5_000)
      catch
        :exit, _ ->
          Enum.each(token_tasks, &Task.shutdown(&1, :brutal_kill))
          Enum.map(new_procs, fn proc -> {proc, %{input: 0, output: 0, cache_read: 0, cache_create: 0, tool_count: 0, last_tool: nil}} end)
      end

    process_sessions =
      token_results
      |> Enum.map(fn {proc, tokens} ->
        started_at =
          case Map.get(proc, :started_at) do
            ms when is_integer(ms) -> DateTime.from_unix!(div(ms, 1000)) |> DateTime.to_iso8601()
            _ -> DateTime.to_iso8601(DateTime.utc_now())
          end

        %{
          session_id: proc.session_id,
          short_id: String.slice(proc.session_id, 0, 8),
          first_seen: started_at,
          last_seen: DateTime.to_iso8601(DateTime.utc_now()),
          tool_count: tokens.tool_count,
          last_tool: tokens.last_tool,
          last_detail: nil,
          run_id: nil,
          model_id: nil,
          total_cost_usd: 0.0,
          total_input_tokens: tokens.input + tokens.cache_read,
          total_output_tokens: tokens.output,
          total_cache_read_tokens: tokens.cache_read,
          total_cache_creation_tokens: tokens.cache_create,
          workspace_path: Map.get(proc, :cwd, ""),
          execution_type: "subscription"
        }
      end)

    # Enrich cost-event sessions that have 0 tokens with transcript data
    enriched_cost =
      Enum.map(cost_sessions, fn sess ->
        if (sess.total_input_tokens || 0) + (sess.total_output_tokens || 0) == 0 do
          tokens = SessionDiscovery.read_transcript_tokens(sess.session_id)

          %{
            sess
            | total_input_tokens: tokens.input + tokens.cache_read,
              total_output_tokens: tokens.output
          }
        else
          sess
        end
      end)

    # Only show sessions with active Claude processes or recent activity (< 2min)
    active_ids = MapSet.new(new_procs ++ safe_call(fn -> SessionDiscovery.active_processes() end, []), & &1.session_id)
    now = DateTime.utc_now()

    (enriched_cost ++ process_sessions)
    |> Enum.filter(fn sess ->
      MapSet.member?(active_ids, sess.session_id) or
        (is_binary(sess.last_seen) and
           case DateTime.from_iso8601(sess.last_seen) do
             {:ok, dt, _} -> DateTime.diff(now, dt, :second) < 120
             _ -> false
           end)
    end)
    |> Enum.sort_by(&(&1.last_seen || ""), :desc)
    |> Enum.take(30)
  rescue
    _ -> []
  end

  defp load_session_events(session_id) do
    # Read directly from transcript — authoritative source for ALL tool calls.
    case SessionDiscovery.read_transcript_events(session_id, 100) do
      events when is_list(events) and events != [] ->
        events

      [] ->
        Logger.warning("TranscriptTailer: no events found for session #{session_id}")
        []

      other ->
        Logger.error("TranscriptTailer: unexpected result for #{session_id}: #{inspect(other)}")
        []
    end
  end

  defp session_duration(session) do
    with first when is_binary(first) <- session.first_seen,
         last when is_binary(last) <- session.last_seen,
         {:ok, d1, _} <- DateTime.from_iso8601(first),
         {:ok, d2, _} <- DateTime.from_iso8601(last) do
      secs = DateTime.diff(d2, d1)

      cond do
        secs < 60 -> "#{secs}s"
        secs < 3600 -> "#{div(secs, 60)}m"
        true -> "#{div(secs, 3600)}h #{rem(div(secs, 60), 60)}m"
      end
    else
      _ -> "—"
    end
  end

  defp workspace_label(session) do
    path = Map.get(session, :workspace_path) || ""

    cond do
      path == "" -> ""
      # Show just the last directory component for brevity
      true -> Path.basename(path)
    end
  end

  defp schedule_refresh(interval), do: Process.send_after(self(), :refresh, interval)

  @doc """
  Cleans up `TranscriptTailer` watches when the LiveView process terminates.
  """
  @impl true
  def terminate(_reason, socket) do
    if session_id = socket.assigns[:expanded_session] do
      try do
        TranscriptTailer.unwatch(session_id)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp maybe_append_event(socket, name, type, snapshot) do
    if name == socket.assigns.team_name do
      entry = %{
        at: DateTime.utc_now(),
        type: type,
        task_count: snapshot.task_count,
        completed: snapshot.completed,
        in_progress: snapshot.in_progress
      }

      events = [entry | socket.assigns.team_events] |> Enum.take(10)
      assign(socket, team_events: events)
    else
      socket
    end
  end

  defp maybe_subscribe_team(socket, team_name) do
    prev = socket.assigns[:subscribed_team]

    if prev && prev != team_name do
      Phoenix.PubSub.unsubscribe(Crucible.PubSub, "team:#{prev}")
    end

    if team_name != prev do
      Events.subscribe_team(team_name)
    end

    assign(socket, subscribed_team: team_name)
  end

  defp maybe_unsubscribe_team(socket) do
    prev = socket.assigns[:subscribed_team]

    if prev do
      Phoenix.PubSub.unsubscribe(Crucible.PubSub, "team:#{prev}")
    end

    assign(socket, subscribed_team: nil)
  end

  defp humanize_team_name(name) do
    # Try structured formats and extract just the workflow part
    result =
      cond do
        # Format: {workflow}-{8+ hex/alphanum}-p{N}  (e.g. coding-sprin-20b74058-p0)
        match = Regex.run(~r/^(.+)-[a-z0-9]{6,12}-p\d+$/, name) ->
          Enum.at(match, 1)

        # Format: {workflow}-{8+ alphanum}-{N}  (e.g. coding-sprint-10jmajgr-0)
        match = Regex.run(~r/^(.+)-[a-z0-9]{6,12}-\d+$/, name) ->
          Enum.at(match, 1)

        true ->
          name
      end

    result
    |> String.replace("-", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  # Show what the team is actually doing as the card title.
  # Priority: first task subject → config description → humanized slug name
  defp team_display_name(team) do
    cond do
      # Use the first task subject if available (most specific)
      match?(%{task_subjects: [s | _]} when is_binary(s) and s != "", team) ->
        hd(team.task_subjects)

      # Fall back to team description from config
      is_binary(Map.get(team, :description)) and Map.get(team, :description) != "" ->
        team.description

      # Last resort: humanize the random slug
      true ->
        humanize_team_name(team.name)
    end
  end

  defp load_scope_options do
    runs = safe_call(fn -> TraceReader.list_runs() end, [])

    client_options =
      runs
      |> Enum.map(&Map.get(&1, :client_id))
      |> ScopeFilters.client_options()

    workspace_options =
      runs
      |> Enum.map(&Map.get(&1, :workspace_path))
      |> ScopeFilters.workspace_options()

    {client_options, workspace_options}
  end

  defp teams_index_path(client_filter, workspace_filter, codebase_filter \\ "all") do
    query =
      %{}
      |> ScopeFilters.apply_scope_query(client_filter, workspace_filter)
      |> then(fn q ->
        if codebase_filter != "all", do: Map.put(q, "codebase", codebase_filter), else: q
      end)

    "/teams" <> encode_query(query)
  end

  defp teams_show_path(name, client_filter, workspace_filter) do
    query =
      %{}
      |> ScopeFilters.apply_scope_query(client_filter, workspace_filter)

    "/teams/#{name}" <> encode_query(query)
  end

  defp encode_query(query) when map_size(query) == 0, do: ""
  defp encode_query(query), do: "?" <> URI.encode_query(query)

  defp build_codebase_options(sessions) do
    codebases =
      sessions
      |> Enum.map(&extract_codebase/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    [%{value: "all", label: "All Codebases"}] ++
      Enum.map(codebases, fn cb -> %{value: cb, label: cb} end)
  end

  defp filter_by_codebase(sessions, "all"), do: sessions

  defp filter_by_codebase(sessions, codebase) do
    Enum.filter(sessions, fn sess -> extract_codebase(sess) == codebase end)
  end

  defp extract_codebase(%{workspace_path: path}) when is_binary(path) and path != "" do
    Path.basename(path)
  end

  defp extract_codebase(_), do: nil
end
