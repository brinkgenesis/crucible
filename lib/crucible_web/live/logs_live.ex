defmodule CrucibleWeb.LogsLive do
  @moduledoc """
  LiveView for the unified log viewer dashboard.

  Presents three log tabs:

    * **System** — structured log files (cost, audit, session, savings) read from
      disk via `LogReader`, with type filtering and text search.
    * **Server** — real-time Erlang/OTP log tail powered by `LogBuffer` and PubSub
      subscription, with level filtering, pause/resume, and clear controls.
    * **Agents** — per-agent trace logs listed from `LogReader.list_agent_logs/1`,
      with a sidebar file picker and detail pane.

  All tabs auto-refresh on a 10-second interval. The server tab additionally
  receives push updates via `Events.subscribe_logs/0` for live tailing.
  """

  use CrucibleWeb, :live_view

  alias Crucible.{Events, LogReader, LogBuffer}

  @refresh_interval 10_000
  @all_levels MapSet.new([:error, :warning, :info, :debug])

  @doc """
  Mounts the LiveView with default assigns and loads system logs.

  On connected mount, schedules a periodic refresh every `@refresh_interval` ms.
  """
  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh(@refresh_interval)

    {:ok,
     assign(socket,
       page_title: "Logs",
       current_path: "/logs",
       active_tab: "system",
       log_type: "cost",
       search_query: "",
       log_entries: [],
       server_logs: [],
       agent_files: [],
       selected_agent: nil,
       agent_entries: [],
       # Live tail state
       log_levels: @all_levels,
       tail_paused: false,
       subscribed_logs: false
     )
     |> load_system_logs()}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @doc """
  Periodic refresh handler. Reloads data for the currently active tab.

  Server tab respects the `tail_paused` flag — when paused, refresh is skipped
  to preserve the user's scroll position.
  """
  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh(@refresh_interval)

    socket =
      case socket.assigns.active_tab do
        "system" -> load_system_logs(socket)
        "server" -> if socket.assigns.tail_paused, do: socket, else: load_server_logs(socket)
        "agents" -> load_agent_files(socket)
        _ -> socket
      end

    {:noreply, socket}
  end

  # Handles a pushed log entry from PubSub. Appends to server_logs (capped at
  # 500) unless tailing is paused or the entry's level is filtered out.
  def handle_info({:log_entry, entry}, socket) do
    if !socket.assigns.tail_paused && MapSet.member?(socket.assigns.log_levels, entry.level) do
      logs = (socket.assigns.server_logs ++ [entry]) |> Enum.take(-500)
      {:noreply, assign(socket, server_logs: logs)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @doc """
  Handles UI events from the log viewer.

  Supported events:

    * `"switch_tab"` — switches active tab, manages PubSub subscription lifecycle
    * `"set_log_type"` — filters system logs by type (cost, audit, session, savings)
    * `"search"` — applies text search to system log entries
    * `"select_agent"` — loads a specific agent's log entries into the detail pane
    * `"toggle_level"` — toggles a log level in the server tail filter
    * `"toggle_pause"` — pauses/resumes live server log tailing
    * `"clear_logs"` — clears all server log entries from the display
  """
  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    socket = manage_log_subscription(socket, tab)

    socket =
      case tab do
        "system" -> assign(socket, active_tab: tab) |> load_system_logs()
        "server" -> assign(socket, active_tab: tab) |> load_server_logs()
        "agents" -> assign(socket, active_tab: tab) |> load_agent_files()
        _ -> assign(socket, active_tab: tab)
      end

    {:noreply, socket}
  end

  def handle_event("set_log_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, log_type: type) |> load_system_logs()}
  end

  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, assign(socket, search_query: query) |> load_system_logs()}
  end

  def handle_event("select_agent", %{"agent-id" => agent_id}, socket) do
    entries = safe_call(fn -> LogReader.read_agent_log(agent_id, limit: 200) end, [])
    {:noreply, assign(socket, selected_agent: agent_id, agent_entries: entries)}
  end

  def handle_event("toggle_level", %{"level" => level_str}, socket) do
    level = String.to_existing_atom(level_str)

    new_levels =
      if MapSet.member?(socket.assigns.log_levels, level),
        do: MapSet.delete(socket.assigns.log_levels, level),
        else: MapSet.put(socket.assigns.log_levels, level)

    # Re-filter existing logs to match new level set
    filtered =
      safe_call(fn -> LogBuffer.recent(500) end, [])
      |> Enum.filter(&MapSet.member?(new_levels, &1.level))

    {:noreply, assign(socket, log_levels: new_levels, server_logs: filtered)}
  end

  def handle_event("toggle_pause", _params, socket) do
    paused = !socket.assigns.tail_paused

    socket = assign(socket, tail_paused: paused)

    socket =
      if !paused do
        # Resuming — reload current buffer and signal scroll
        socket = load_server_logs(socket)
        push_event(socket, "scroll-bottom", %{})
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("clear_logs", _params, socket) do
    {:noreply, assign(socket, server_logs: [])}
  end

  # ---------------------------------------------------------------------------
  # Data loading
  # ---------------------------------------------------------------------------

  defp load_system_logs(socket) do
    type = String.to_existing_atom(socket.assigns.log_type)
    search = socket.assigns.search_query
    search_opt = if search != "", do: search, else: nil

    entries = safe_call(fn -> LogReader.read_log(type, limit: 100, search: search_opt) end, [])
    assign(socket, log_entries: entries)
  end

  defp load_server_logs(socket) do
    logs =
      safe_call(fn -> LogBuffer.recent(500) end, [])
      |> Enum.filter(&MapSet.member?(socket.assigns.log_levels, &1.level))

    assign(socket, server_logs: logs)
  end

  defp load_agent_files(socket) do
    files = safe_call(fn -> LogReader.list_agent_logs(limit: 50) end, [])
    assign(socket, agent_files: files)
  end

  defp manage_log_subscription(socket, new_tab) do
    was_server = socket.assigns.subscribed_logs

    cond do
      new_tab == "server" && !was_server ->
        Events.subscribe_logs()
        assign(socket, subscribed_logs: true)

      new_tab != "server" && was_server ->
        Phoenix.PubSub.unsubscribe(Crucible.PubSub, "logs:server")
        assign(socket, subscribed_logs: false)

      true ->
        socket
    end
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @doc """
  Renders the log viewer with tabbed navigation, filter controls, and log entry lists.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <%!-- Page header --%>
        <div class="flex justify-between items-end border-b-2 border-[#ffa44c]/20 pb-3">
          <div>
            <h1 class="text-3xl font-headline font-bold text-[#ffa44c] tracking-tighter uppercase">
              EVENT_LOG_STREAM
            </h1>
            <p class="font-mono text-xs text-[#00eefc] opacity-70">
              SYSTEM_TELEMETRY // REALTIME_CAPTURE_ACTIVE
            </p>
          </div>
        </div>

        <%!-- Tabs --%>
        <div class="bg-surface-container-low border border-[#ffa44c]/10 p-1 flex font-headline font-bold text-sm">
          <button
            :for={
              {tab, label, icon} <- [
                {"system", "SYSTEM_LOG", "database"},
                {"server", "SERVER_TAIL", "terminal"},
                {"agents", "AGENT_TRACE", "smart_toy"}
              ]
            }
            phx-click="switch_tab"
            phx-value-tab={tab}
            class={[
              "flex-1 py-2 uppercase tracking-widest transition-all flex items-center justify-center gap-2 text-xs",
              if(@active_tab == tab,
                do: "bg-[#00eefc] text-black font-bold",
                else: "text-[#ffa44c]/60 hover:bg-surface-container-high"
              )
            ]}
          >
            <span class="material-symbols-outlined text-sm">{icon}</span> {label}
          </button>
        </div>

        <%!-- System Logs tab --%>
        <div :if={@active_tab == "system"} class="space-y-4">
          <div class="flex flex-wrap items-center gap-2">
            <button
              :for={
                {type, label} <- [
                  {"cost", "COST"},
                  {"audit", "AUDIT"},
                  {"session", "SESSION"},
                  {"savings", "SAVINGS"}
                ]
              }
              phx-click="set_log_type"
              phx-value-type={type}
              class={[
                "px-3 py-1 font-mono text-[10px] font-bold transition-colors",
                if(@log_type == type,
                  do: "bg-[#ffa44c] text-black",
                  else:
                    "border border-[#494847] text-[#494847] hover:border-[#00eefc] hover:text-[#00eefc]"
                )
              ]}
            >
              {label}
            </button>
            <div class="flex-1" />
            <form phx-change="search" class="flex-shrink-0">
              <input
                type="text"
                name="query"
                value={@search_query}
                placeholder="FILTER_LOGS..."
                class="bg-black border border-[#494847] text-[10px] font-mono px-3 py-1 text-[#ffa44c] focus:outline-none focus:border-[#00eefc] w-48"
                phx-debounce="300"
              />
            </form>
          </div>

          <div :if={@log_entries == []} class="text-center py-12 text-[#494847]">
            <span class="material-symbols-outlined text-4xl opacity-30">database</span>
            <p class="font-mono text-[10px] mt-2">NO_LOG_ENTRIES_FOUND</p>
          </div>

          <div
            :if={@log_entries != []}
            class="bg-surface-container-low border border-[#ffa44c]/10 overflow-hidden"
          >
            <div class="max-h-[600px] overflow-y-auto" id="log-entries">
              <div class="divide-y divide-[#494847]/5">
                <%= for entry <- Enum.reverse(@log_entries) do %>
                  <.log_entry_row entry={entry} type={@log_type} />
                <% end %>
              </div>
            </div>
          </div>
        </div>

        <%!-- Server Logs tab --%>
        <div :if={@active_tab == "server"} class="space-y-4">
          <.server_toolbar
            log_levels={@log_levels}
            tail_paused={@tail_paused}
            count={length(@server_logs)}
          />

          <div :if={@server_logs == []} class="text-center py-12 text-[#494847]">
            <span class="material-symbols-outlined text-4xl opacity-30">terminal</span>
            <p class="font-mono text-[10px] mt-2">NO_SERVER_ENTRIES_CAPTURED</p>
          </div>

          <div
            :if={@server_logs != []}
            class="bg-surface-container-low border border-[#ffa44c]/10 overflow-hidden"
          >
            <div
              class="max-h-[600px] overflow-y-auto font-mono divide-y divide-[#494847]/5"
              id="server-log-entries"
              phx-hook="LogTail"
            >
              <div
                :for={entry <- @server_logs}
                class={[
                  "flex items-start gap-3 px-4 py-2 text-[11px] border-l-2",
                  level_border(entry.level)
                ]}
              >
                <span class="text-[#494847] w-16 shrink-0">
                  {format_time(entry.timestamp)}
                </span>
                <span class={[
                  "px-1.5 py-0.5 text-[8px] font-bold shrink-0",
                  level_hud_badge(entry.level)
                ]}>
                  {entry.level}
                </span>
                <span :if={entry.module} class="text-[#494847] shrink-0">
                  {short_module(entry.module)}
                </span>
                <span class="text-white/80 truncate">
                  {entry.message}
                </span>
              </div>
            </div>
          </div>
        </div>

        <%!-- Agent Logs tab --%>
        <div :if={@active_tab == "agents"} class="grid grid-cols-12 gap-6">
          <div class="col-span-12 lg:col-span-3">
            <div class="bg-surface-container-low border border-[#ffa44c]/10 overflow-y-auto max-h-[600px]">
              <div class="sticky top-0 bg-surface-container-low px-4 py-2 border-b border-[#494847]/20">
                <span class="font-mono text-[10px] text-[#ffa44c]">AGENT_FILES</span>
              </div>
              <div :if={@agent_files == []} class="p-4 text-[#494847] font-mono text-[10px]">
                NO_AGENT_LOGS_FOUND
              </div>
              <div class="divide-y divide-[#494847]/10">
                <button
                  :for={f <- @agent_files}
                  phx-click="select_agent"
                  phx-value-agent-id={f.id}
                  class={[
                    "w-full text-left p-3 hover:bg-surface-container-high transition-colors",
                    @selected_agent == f.id && "bg-surface-container-high border-l-4 border-[#00eefc]"
                  ]}
                >
                  <div class="font-mono text-[10px] text-[#ffa44c] truncate">
                    {String.slice(f.id, 0, 20)}
                  </div>
                  <div class="text-[9px] font-mono text-[#494847]">{format_size(f.size)}</div>
                </button>
              </div>
            </div>
          </div>

          <div class="col-span-12 lg:col-span-9">
            <div
              :if={!@selected_agent}
              class="bg-surface-container-low border border-[#ffa44c]/10 text-center py-12"
            >
              <span class="material-symbols-outlined text-4xl text-[#494847]/30">smart_toy</span>
              <p class="font-mono text-[10px] text-[#494847] mt-2">SELECT_AGENT_LOG_TO_VIEW</p>
            </div>

            <div
              :if={@selected_agent && @agent_entries == []}
              class="bg-surface-container-low border border-[#ffa44c]/10 text-center py-12"
            >
              <p class="font-mono text-[10px] text-[#494847]">NO_ENTRIES_IN_LOG</p>
            </div>

            <div
              :if={@agent_entries != []}
              class="bg-surface-container-low border border-[#ffa44c]/10 overflow-hidden"
            >
              <div
                class="max-h-[600px] overflow-y-auto divide-y divide-[#494847]/5"
                id="agent-entries"
              >
                <div
                  :for={entry <- @agent_entries}
                  class="flex items-start gap-3 px-4 py-2 hover:bg-surface-container-high text-[11px] font-mono"
                >
                  <span class="text-[#494847] w-16 shrink-0">
                    {format_time(entry["timestamp"])}
                  </span>
                  <.agent_event_badge event={entry["event"]} />
                  <span
                    :if={entry["agent_type"]}
                    class="px-1.5 py-0.5 bg-[#494847]/10 border border-[#494847]/30 text-[8px] text-[#494847] shrink-0"
                  >
                    {entry["agent_type"]}
                  </span>
                  <span class="text-white/80 truncate">
                    {entry["teammate_name"] || entry["agent_id"] || entry["event"] || "—"}
                  </span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Server toolbar component
  # ---------------------------------------------------------------------------

  attr :log_levels, :any, required: true
  attr :tail_paused, :boolean, required: true
  attr :count, :integer, required: true

  defp server_toolbar(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <%!-- Level filter pills --%>
      <button
        :for={
          {level, label, color} <- [
            {:error, "ERROR", "bg-[#ff7351] text-black"},
            {:warning, "WARN", "bg-[#ffa44c] text-black"},
            {:info, "INFO", "bg-[#00eefc] text-black"},
            {:debug, "DEBUG", "border border-[#494847] text-[#494847]"}
          ]
        }
        class={[
          "px-2 py-0.5 font-mono text-[9px] font-bold transition-colors",
          if(MapSet.member?(@log_levels, level),
            do: color,
            else: "border border-[#494847]/30 text-[#494847]/30"
          )
        ]}
        phx-click="toggle_level"
        phx-value-level={level}
      >
        {label}
      </button>

      <div class="flex-1" />

      <%!-- Live indicator --%>
      <span :if={!@tail_paused} class="flex items-center gap-2 text-[10px] font-mono text-[#00FF41]">
        <span class="w-2 h-2 bg-[#00FF41] animate-pulse shadow-[0_0_8px_#00FF41]"></span> LIVE
      </span>
      <span :if={@tail_paused} class="flex items-center gap-2 text-[10px] font-mono text-[#494847]">
        <span class="w-2 h-2 bg-[#494847]"></span> PAUSED
      </span>

      <%!-- Entry count --%>
      <span class="font-mono text-[10px] text-[#ffa44c]">{@count} ENTRIES</span>

      <%!-- Pause / Resume --%>
      <button
        phx-click="toggle_pause"
        class={[
          "px-3 py-1 font-mono text-[10px] font-bold transition-colors flex items-center gap-1",
          if(@tail_paused,
            do: "bg-[#00FF41]/10 border border-[#00FF41]/30 text-[#00FF41]",
            else: "border border-[#494847] text-[#494847] hover:border-[#ffa44c]"
          )
        ]}
      >
        <span class="material-symbols-outlined text-xs">
          {if(@tail_paused, do: "play_arrow", else: "pause")}
        </span>
        {if(@tail_paused, do: "RESUME", else: "PAUSE")}
      </button>

      <%!-- Clear --%>
      <button
        class="px-3 py-1 font-mono text-[10px] border border-[#494847] text-[#494847] hover:border-[#ff725e] hover:text-[#ff725e] transition-colors flex items-center gap-1"
        phx-click="clear_logs"
      >
        <span class="material-symbols-outlined text-xs">delete</span> CLEAR
      </button>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Log entry row component
  # ---------------------------------------------------------------------------

  attr :entry, :map, required: true
  attr :type, :string, required: true

  defp log_entry_row(%{type: "cost"} = assigns) do
    ~H"""
    <div class="flex items-center gap-3 px-4 py-2 hover:bg-[#ffa44c]/5 transition-colors font-mono text-[11px]">
      <span class="text-[#494847] w-16 shrink-0">{format_time(@entry["timestamp"])}</span>
      <.tool_badge tool={@entry["tool"]} />
      <span class="text-[#494847] shrink-0">{String.slice(@entry["session"] || "", 0, 8)}</span>
      <span class="text-white/70 truncate flex-1">{@entry["detail"] || "—"}</span>
      <span
        :if={@entry["costUsd"] && @entry["costUsd"] > 0}
        class="text-[#00FF41] font-bold shrink-0"
      >
        ${Float.round((@entry["costUsd"] || 0.0) * 1.0, 4)}
      </span>
    </div>
    """
  end

  defp log_entry_row(%{type: "audit"} = assigns) do
    ~H"""
    <div class="flex items-center gap-3 px-4 py-2 hover:bg-[#ffa44c]/5 transition-colors font-mono text-[11px]">
      <span class="text-[#494847] w-16 shrink-0">{format_time(@entry["timestamp"])}</span>
      <.tool_badge tool={@entry["tool"]} />
      <span class={["px-1.5 py-0.5 text-[8px] font-bold shrink-0", audit_hud_class(@entry["status"])]}>
        {@entry["status"] || "—"}
      </span>
      <span :if={@entry["durationMs"]} class="text-[#494847] shrink-0">{@entry["durationMs"]}ms</span>
      <span class="text-white/70 truncate flex-1">{truncate_args(@entry["args"])}</span>
    </div>
    """
  end

  defp log_entry_row(%{type: "session"} = assigns) do
    ~H"""
    <div class="flex items-center gap-3 px-4 py-2 hover:bg-[#ffa44c]/5 transition-colors font-mono text-[11px]">
      <span class="text-[#494847] w-16 shrink-0">{format_time(@entry["timestamp"])}</span>
      <span class={["px-1.5 py-0.5 text-[8px] font-bold shrink-0", session_hud_class(@entry["event"])]}>
        {@entry["event"] || "—"}
      </span>
      <span class="text-[#494847]">{String.slice(@entry["session"] || "", 0, 8)}</span>
      <span
        :if={@entry["is_teammate"]}
        class="px-1.5 py-0.5 bg-[#ffa44c]/10 border border-[#ffa44c]/30 text-[8px] text-[#ffa44c] font-bold shrink-0"
      >
        TEAMMATE
      </span>
    </div>
    """
  end

  defp log_entry_row(%{type: "savings"} = assigns) do
    ~H"""
    <div class="flex items-center gap-3 px-4 py-2 hover:bg-[#ffa44c]/5 transition-colors font-mono text-[11px]">
      <span class="text-[#494847] w-16 shrink-0">{format_time(@entry["timestamp"])}</span>
      <span class="px-1.5 py-0.5 bg-[#494847]/10 border border-[#494847]/30 text-[8px] text-[#494847] shrink-0">
        {@entry["operation"] || "—"}
      </span>
      <span class={["font-bold shrink-0", savings_hud_color(@entry["savedRatio"])]}>
        {format_ratio(@entry["savedRatio"])}
      </span>
      <span class="text-[#494847]">
        {@entry["compactTokens"] || 0} / {@entry["naiveTokens"] || 0} tokens
      </span>
      <span class="text-white/70 truncate flex-1">{@entry["query"] || "—"}</span>
    </div>
    """
  end

  defp log_entry_row(assigns) do
    ~H"""
    <div class="flex items-center gap-3 px-4 py-2 hover:bg-[#ffa44c]/5 transition-colors font-mono text-[11px]">
      <span class="text-[#494847] w-16 shrink-0">{format_time(@entry["timestamp"])}</span>
      <span class="text-white/70 truncate">{inspect(@entry)}</span>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helper components
  # ---------------------------------------------------------------------------

  attr :tool, :string, default: nil

  defp tool_badge(assigns) do
    assigns = assign(assigns, :class, tool_hud_class(assigns.tool))

    ~H"""
    <span :if={@tool} class={["px-1.5 py-0.5 text-[8px] font-bold font-mono shrink-0", @class]}>
      {@tool}
    </span>
    """
  end

  attr :event, :string, default: nil

  defp agent_event_badge(assigns) do
    {class, label} =
      case assigns.event do
        "subagent_start" ->
          {"bg-[#00FF41]/10 text-[#00FF41] border border-[#00FF41]/30", "START"}

        "subagent_stop" ->
          {"bg-[#ffa44c]/10 text-[#ffa44c] border border-[#ffa44c]/30", "STOP"}

        "teammate_idle" ->
          {"bg-[#494847]/10 text-[#494847] border border-[#494847]/30", "IDLE"}

        "ghost_agent_detected" ->
          {"bg-[#ff7351] text-black", "GHOST"}

        e when is_binary(e) ->
          {"bg-[#494847]/10 text-[#494847] border border-[#494847]/30", String.upcase(e)}

        _ ->
          {"bg-[#494847]/10 text-[#494847]", "—"}
      end

    assigns = assign(assigns, class: class, label: label)

    ~H"""
    <span class={["px-1.5 py-0.5 text-[8px] font-bold shrink-0", @class]}>{@label}</span>
    """
  end

  defp format_size(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)}MB"
  defp format_size(bytes) when bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)}KB"
  defp format_size(bytes), do: "#{bytes}B"

  defp format_ratio(nil), do: "—"
  defp format_ratio(r) when is_number(r), do: "#{Float.round(r * 100.0, 1)}%"

  defp tool_hud_class(nil), do: "bg-[#494847]/10 text-[#494847]"
  defp tool_hud_class("Read"), do: "bg-[#00eefc]/10 text-[#00eefc] border border-[#00eefc]/30"
  defp tool_hud_class("Edit"), do: "bg-[#ffa44c]/10 text-[#ffa44c] border border-[#ffa44c]/30"
  defp tool_hud_class("Write"), do: "bg-[#ffa44c]/10 text-[#ffa44c] border border-[#ffa44c]/30"
  defp tool_hud_class("Bash"), do: "bg-[#00FF41]/10 text-[#00FF41] border border-[#00FF41]/30"
  defp tool_hud_class("Grep"), do: "bg-[#00eefc]/10 text-[#00eefc] border border-[#00eefc]/30"
  defp tool_hud_class("Glob"), do: "bg-[#00eefc]/10 text-[#00eefc] border border-[#00eefc]/30"
  defp tool_hud_class("Agent"), do: "bg-[#ffa44c]/10 text-[#ffa44c] border border-[#ffa44c]/30"

  defp tool_hud_class("mcp__" <> _),
    do: "bg-[#494847]/10 text-[#494847] border border-[#494847]/30"

  defp tool_hud_class(_), do: "bg-[#494847]/10 text-[#494847] border border-[#494847]/30"

  defp audit_hud_class("success"), do: "bg-[#00FF41]/10 text-[#00FF41] border border-[#00FF41]/30"
  defp audit_hud_class("error"), do: "bg-[#ff7351] text-black"
  defp audit_hud_class(_), do: "bg-[#494847]/10 text-[#494847] border border-[#494847]/30"

  defp session_hud_class("session_start"),
    do: "bg-[#00eefc]/10 text-[#00eefc] border border-[#00eefc]/30"

  defp session_hud_class("session_end"),
    do: "bg-[#494847]/10 text-[#494847] border border-[#494847]/30"

  defp session_hud_class("session_stop"),
    do: "bg-[#494847]/10 text-[#494847] border border-[#494847]/30"

  defp session_hud_class(_), do: "bg-[#494847]/10 text-[#494847] border border-[#494847]/30"

  defp savings_hud_color(nil), do: "text-[#494847]"
  defp savings_hud_color(r) when is_number(r) and r >= 0.5, do: "text-[#ffa44c]"
  defp savings_hud_color(r) when is_number(r) and r >= 0.2, do: "text-[#00eefc]"
  defp savings_hud_color(_), do: "text-[#494847]"

  defp level_border(:error), do: "border-[#ff7351]"
  defp level_border(:warning), do: "border-[#ffa44c]"
  defp level_border(:info), do: "border-[#00eefc]"
  defp level_border(:debug), do: "border-[#494847]/20"
  defp level_border(_), do: "border-[#494847]/10"

  defp level_hud_badge(:error), do: "bg-[#ff7351] text-black"
  defp level_hud_badge(:warning), do: "bg-[#ffa44c] text-black"
  defp level_hud_badge(:info), do: "bg-[#00eefc]/10 text-[#00eefc] border border-[#00eefc]/30"
  defp level_hud_badge(:debug), do: "bg-[#494847]/10 text-[#494847] border border-[#494847]/30"
  defp level_hud_badge(_), do: "bg-[#494847]/10 text-[#494847]"

  defp short_module(nil), do: nil

  defp short_module(mod) when is_binary(mod) do
    mod |> String.split(".") |> List.last()
  end

  defp truncate_args(nil), do: "—"

  defp truncate_args(args) when is_map(args) do
    s = inspect(args, limit: 5, printable_limit: 30)
    if String.length(s) > 40, do: String.slice(s, 0, 37) <> "...", else: s
  end

  defp truncate_args(args), do: inspect(args) |> String.slice(0, 40)

  defp schedule_refresh(interval), do: Process.send_after(self(), :refresh, interval)
end
