defmodule CrucibleWeb.AuditLive do
  @moduledoc """
  LiveView page for the Audit Trail dashboard (`/audit`).

  Displays a paginated, filterable table of audit events sourced from
  `Crucible.AuditTrail.query/1`. Supports:

  * **Action filtering** — dropdown of known action types (login, config.update,
    workflow.trigger, etc.) to narrow the event list.
  * **Pagination** — server-side paging at 50 events per page.
  * **Auto-refresh** — polls for new events every 15 seconds via `RefreshTimer`.

  All data fetching is wrapped in `safe_call/2` so transient backend errors
  degrade gracefully to an empty state rather than crashing the view.
  """
  use CrucibleWeb, :live_view

  alias CrucibleWeb.Live.RefreshTimer

  alias Crucible.Audit

  @refresh_interval 15_000
  @health_check_interval 30_000
  @page_size 50

  # Covers both JSONL-originated actions (dotted) and DB-native event types
  @valid_actions ~w(
    login logout config.update env.update budget.update
    workflow.trigger workflow.view client.create client.update
    client.delete client.team.add client.team.remove
    client.config.update kanban.card.move kanban.card.create
    kanban.card.update circuit.reset remote.session.start
    remote.session.kill audit.query
    created updated deleted moved archived restored
    status_changed card_linked cancelled completed failed upserted
  )

  @doc """
  Initializes the audit log LiveView with default filter state and starts
  the auto-refresh timer for connected clients.
  """
  @impl true
  def mount(_params, _session, socket) do
    timer = if connected?(socket), do: RefreshTimer.start(@refresh_interval)
    if connected?(socket), do: Process.send_after(self(), :health_check, @health_check_interval)

    health = safe_call(fn -> Audit.health_check() end, %{event_count: 0, latest_timestamp: nil})

    {:ok,
     assign(socket,
       page_title: "Audit Log",
       refresh_timer: timer,
       current_path: "/audit",
       events: [],
       total: 0,
       page: 1,
       action_filter: "all",
       valid_actions: ["all" | @valid_actions],
       loading: !connected?(socket),
       health: health
     )
     |> load_data()}
  end

  @impl true
  def terminate(_reason, socket) do
    RefreshTimer.cancel(socket.assigns[:refresh_timer])
  end

  @doc false
  @impl true
  def handle_info(:refresh, socket) do
    socket = load_data(socket)
    timer = RefreshTimer.tick(socket.assigns[:refresh_timer], true)
    {:noreply, assign(socket, refresh_timer: timer)}
  end

  def handle_info(:health_check, socket) do
    health = safe_call(fn -> Audit.health_check() end, socket.assigns.health)
    Process.send_after(self(), :health_check, @health_check_interval)
    {:noreply, assign(socket, health: health)}
  end

  @doc """
  Handles UI events: `"filter_action"` applies an action-type filter and
  resets to page 1; `"page"` navigates to the given page number.
  """
  @impl true
  def handle_event("filter_action", %{"action" => action}, socket) do
    {:noreply, assign(socket, action_filter: action, page: 1) |> load_data()}
  end

  def handle_event("page", %{"page" => page_str}, socket) do
    page = max(1, String.to_integer(page_str))
    {:noreply, assign(socket, page: page) |> load_data()}
  end

  defp load_data(socket) do
    offset = (socket.assigns.page - 1) * @page_size

    opts =
      [limit: @page_size, offset: offset]
      |> maybe_filter(:event_type, socket.assigns.action_filter)

    {events, total} = safe_call(fn -> Audit.list_events(opts) end, {[], 0})

    assign(socket,
      events: events,
      total: total,
      loading: false
    )
  end

  defp maybe_filter(opts, _key, "all"), do: opts
  defp maybe_filter(opts, key, value), do: Keyword.put(opts, key, value)

  @impl true
  def render(assigns) do
    total_pages = max(1, ceil(assigns.total / @page_size))
    assigns = assign(assigns, total_pages: total_pages)

    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <.hud_header icon="security" label="AUDIT_TRAIL" />
        
    <!-- Health check banner -->
        <div class="flex items-center gap-4 bg-surface-container-low hud-border p-3">
          <span class="material-symbols-outlined text-sm text-[#00FF41]/60">monitor_heart</span>
          <span class="font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60">
            DB Health
          </span>
          <span class="font-mono text-[11px] text-[#e0e0e0]/70">
            {@health.event_count} events
          </span>
          <span class="font-mono text-[11px] text-[#e0e0e0]/40">
            Latest: {format_health_ts(@health.latest_timestamp)}
          </span>
        </div>
        
    <!-- Header stats -->
        <div class="flex items-center gap-6">
          <.hud_stat label="TOTAL EVENTS" value={Integer.to_string(@total)} color="primary" />
          <.hud_stat label="FILTER" value={String.upcase(@action_filter)} color="secondary" />
          <.hud_stat label="PAGE" value={"#{@page}/#{@total_pages}"} color="tertiary" />
        </div>
        
    <!-- Loading -->
        <div :if={@loading} class="bg-surface-container-low hud-border animate-pulse">
          <div class="p-5"><div class="h-48 bg-surface-container rounded" /></div>
        </div>

        <div :if={!@loading} class="space-y-4">
          <!-- Filter bar -->
          <div class="flex items-center gap-4 flex-wrap bg-surface-container-low hud-border p-3">
            <span class="font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60">
              Action Filter
            </span>
            <select
              phx-change="filter_action"
              name="action"
              class="bg-surface-container border border-[#ffa44c]/20 text-[#e0e0e0] font-mono text-xs px-3 py-1.5 rounded focus:border-[#00eefc]/50 focus:outline-none"
            >
              <option :for={a <- @valid_actions} value={a} selected={a == @action_filter}>
                {a}
              </option>
            </select>
            <span class="ml-auto font-mono text-[11px] text-[#ffa44c]/40">
              {Integer.to_string(@total)} records
            </span>
          </div>
          
    <!-- Events table -->
          <.hud_card>
            <div :if={@events == []} class="text-center py-8 text-[#e0e0e0]/30">
              <span class="material-symbols-outlined text-3xl opacity-30 block mb-2">
                verified_user
              </span>
              <p class="font-mono text-[10px] text-neutral-500">NO_AUDIT_EVENTS_FOUND</p>
            </div>
            <div :if={@events != []} class="overflow-x-auto">
              <table class="w-full">
                <thead>
                  <tr class="border-b border-[#ffa44c]/10">
                    <th class="text-left font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-2 px-3">
                      Timestamp
                    </th>
                    <th class="text-left font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-2 px-3">
                      Action
                    </th>
                    <th class="text-left font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-2 px-3">
                      User
                    </th>
                    <th class="text-left font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-2 px-3">
                      Resource
                    </th>
                    <th class="text-left font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-2 px-3">
                      Details
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={evt <- @events}
                    class="border-b border-[#ffa44c]/5 hover:bg-[#ffa44c]/5 transition-colors"
                  >
                    <td class="font-mono text-[11px] text-[#e0e0e0]/50 py-2 px-3">
                      {format_ts(evt)}
                    </td>
                    <td class="py-2 px-3">
                      <span class={[
                        "px-1.5 py-0.5 font-mono text-[8px] font-bold uppercase border rounded",
                        action_hud_badge(evt)
                      ]}>
                        {evt.event_type}
                      </span>
                    </td>
                    <td class="font-mono text-[11px] text-[#e0e0e0]/70 py-2 px-3">
                      {evt.actor || "—"}
                    </td>
                    <td class="font-mono text-[11px] text-[#00eefc]/60 truncate max-w-[200px] py-2 px-3">
                      {evt.entity_type}/{evt.entity_id}
                    </td>
                    <td class="font-mono text-[11px] text-[#e0e0e0]/40 truncate max-w-[250px] py-2 px-3">
                      {format_details(evt)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
            
    <!-- Pagination -->
            <div
              :if={@total_pages > 1}
              class="flex justify-center items-center gap-2 mt-4 pt-3 border-t border-[#ffa44c]/10"
            >
              <button
                :if={@page > 1}
                phx-click="page"
                phx-value-page={@page - 1}
                class="px-3 py-1 font-mono text-[10px] tracking-widest uppercase text-[#00eefc]/60 hover:text-[#00eefc] hover:bg-[#00eefc]/10 rounded transition-colors"
              >
                <span class="material-symbols-outlined text-sm align-middle">chevron_left</span> PREV
              </button>
              <span class="font-mono text-[11px] text-[#ffa44c]/60">
                {@page} / {@total_pages}
              </span>
              <button
                :if={@page < @total_pages}
                phx-click="page"
                phx-value-page={@page + 1}
                class="px-3 py-1 font-mono text-[10px] tracking-widest uppercase text-[#00eefc]/60 hover:text-[#00eefc] hover:bg-[#00eefc]/10 rounded transition-colors"
              >
                NEXT <span class="material-symbols-outlined text-sm align-middle">chevron_right</span>
              </button>
            </div>
          </.hud_card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp format_ts(evt) do
    case evt.occurred_at do
      nil -> "—"
      dt -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
    end
  end

  defp format_details(evt) do
    case evt.payload do
      nil -> "—"
      p when map_size(p) == 0 -> "—"
      p when is_map(p) -> Jason.encode!(p) |> String.slice(0, 80)
    end
  end

  defp format_health_ts(nil), do: "—"
  defp format_health_ts(ts), do: Calendar.strftime(ts, "%Y-%m-%d %H:%M:%S")

  defp action_hud_badge(evt) do
    case evt.event_type do
      "login" ->
        "text-[#00FF41] border-[#00FF41]/30"

      "logout" ->
        "text-[#e0e0e0]/40 border-[#e0e0e0]/10"

      a when a in ~w(deleted client.delete remote.session.kill cancelled failed) ->
        "text-[#ff7351] border-[#ff7351]/30"

      a when a in ~w(updated config.update env.update budget.update status_changed moved) ->
        "text-[#ffa44c] border-[#ffa44c]/30"

      a when a in ~w(created completed restored) ->
        "text-[#00FF41] border-[#00FF41]/30"

      _ ->
        "text-[#00eefc] border-[#00eefc]/30"
    end
  end
end
