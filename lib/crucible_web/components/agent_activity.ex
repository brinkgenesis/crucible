defmodule CrucibleWeb.Components.AgentActivity do
  @moduledoc "Per-agent session activity components — NERV tactical HUD styling."
  use CrucibleWeb, :html

  # ---------------------------------------------------------------------------
  # Run-scoped activity (detail view Activity tab)
  # ---------------------------------------------------------------------------

  attr :sessions, :list, required: true
  attr :expanded_session, :string, default: nil
  attr :session_events, :list, default: []
  attr :ts_api_up, :boolean, default: true

  def run_activity(assigns) do
    ~H"""
    <div
      :if={!@ts_api_up}
      class="bg-[#ff7351]/10 border border-[#ff7351]/20 p-3 flex items-center gap-2"
    >
      <span class="material-symbols-outlined text-sm text-[#ff7351]">signal_disconnected</span>
      <span class="text-[10px] font-label tracking-widest text-[#ff7351]">
        ACTIVITY_DATA_UNAVAILABLE
      </span>
    </div>

    <div :if={@ts_api_up and @sessions == []} class="text-center py-8">
      <span class="material-symbols-outlined text-4xl text-[#494847]/30">bolt</span>
      <p class="text-[10px] font-label text-[#adaaaa]/40 mt-2">NO_AGENT_SESSIONS_DETECTED</p>
    </div>

    <div :if={@ts_api_up and @sessions != []} class="space-y-2">
      <div :for={session <- @sessions} class="bg-surface-container-low hud-border overflow-hidden">
        <button
          phx-click="toggle_session"
          phx-value-session-id={session["sessionId"]}
          class="w-full flex items-center gap-3 p-3 hover:bg-[#ffa44c]/5 transition-colors text-left"
        >
          <.status_dot active={!session["isEnded"]} />
          <div class="flex-1 min-w-0">
            <div class="font-label text-xs text-white truncate">
              {session["displayName"] || session["shortId"] || "UNKNOWN"}
            </div>
            <div class="text-[10px] font-label text-[#adaaaa]/60 truncate">
              {session["lastDetail"] || "—"}
            </div>
          </div>
          <.tool_badge tool={session["lastTool"]} />
          <span class="text-[10px] font-label text-[#adaaaa]/40">
            {session["toolCount"] || 0} CALLS
          </span>
          <span class="text-[10px] font-label text-[#ffa44c]/40">
            {format_session_duration(session["firstSeen"], session["lastSeen"])}
          </span>
          <span class="material-symbols-outlined text-sm text-[#ffa44c]/40">
            {if @expanded_session == session["sessionId"], do: "expand_less", else: "expand_more"}
          </span>
        </button>

        <div :if={@expanded_session == session["sessionId"]} class="border-t border-[#ffa44c]/10">
          <div
            :if={@session_events == []}
            class="p-4 text-center text-[10px] font-label text-[#adaaaa]/40"
          >
            NO_EVENTS_RECORDED
          </div>

          <div
            :if={@session_events != []}
            class="max-h-[400px] overflow-y-auto divide-y divide-[#ffa44c]/5"
            id="session-events"
            phx-hook="ScrollBottom"
          >
            <div
              :for={event <- @session_events}
              class="flex items-center gap-3 px-3 py-1.5 hover:bg-[#ffa44c]/5"
            >
              <span class="text-[10px] font-label text-[#ffa44c]/40 w-16 shrink-0">
                {format_event_time(event["timestamp"])}
              </span>
              <.tool_badge tool={event["tool"]} />
              <span class="text-[10px] font-label text-[#adaaaa]/70 truncate">
                {event["detail"] || event["tool"]}
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Global activity feed (runs list page)
  # ---------------------------------------------------------------------------

  attr :sessions, :list, required: true
  attr :ts_api_up, :boolean, default: true

  def global_activity(assigns) do
    active = Enum.reject(assigns.sessions, & &1["isEnded"])
    assigns = assign(assigns, :active, active)

    ~H"""
    <div :if={!@ts_api_up} class="text-[10px] font-label text-[#adaaaa]/40 py-2">
      TS_DASHBOARD_UNAVAILABLE
    </div>

    <div :if={@ts_api_up and @active == []} class="text-[10px] font-label text-[#adaaaa]/40 py-2">
      NO_ACTIVE_SESSIONS
    </div>

    <div
      :if={@ts_api_up and @active != []}
      class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-2"
    >
      <div :for={s <- @active} class="flex items-center gap-2 p-2 bg-surface-container-low hud-border">
        <.status_dot active={true} />
        <div class="flex-1 min-w-0">
          <div class="text-xs font-label text-white truncate">
            {s["displayName"] || s["shortId"]}
          </div>
          <div class="text-[10px] font-label text-[#adaaaa]/60 truncate">
            {s["lastDetail"] || "—"}
          </div>
        </div>
        <.tool_badge tool={s["lastTool"]} />
        <span class="text-[10px] font-label text-[#ffa44c]/40">{s["toolCount"]}</span>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  attr :active, :boolean, required: true

  defp status_dot(assigns) do
    ~H"""
    <span class={[
      "inline-block w-2 h-2 shrink-0",
      @active && "bg-[#00FF41] shadow-[0_0_6px_#00FF41] animate-pulse",
      !@active && "bg-[#494847]"
    ]} />
    """
  end

  attr :tool, :string, default: nil

  defp tool_badge(assigns) do
    assigns = assign(assigns, :class, tool_hud_class(assigns.tool))
    assigns = assign(assigns, :label, short_tool_name(assigns.tool))

    ~H"""
    <span
      :if={@tool}
      class={["px-1.5 py-0.5 text-[9px] font-label tracking-wider border shrink-0", @class]}
    >
      {@label}
    </span>
    """
  end

  defp tool_hud_class(nil), do: "text-[#adaaaa]/40 border-[#494847]/30"
  defp tool_hud_class("Read"), do: "text-[#00eefc] border-[#00eefc]/30"
  defp tool_hud_class("Edit"), do: "text-[#ffa44c] border-[#ffa44c]/30"
  defp tool_hud_class("Write"), do: "text-[#ffa44c] border-[#ffa44c]/30"
  defp tool_hud_class("Bash"), do: "text-[#00FF41] border-[#00FF41]/30"
  defp tool_hud_class("Grep"), do: "text-[#00eefc] border-[#00eefc]/30"
  defp tool_hud_class("Glob"), do: "text-[#00eefc] border-[#00eefc]/30"
  defp tool_hud_class("Agent"), do: "text-[#fd9000] border-[#fd9000]/30"
  defp tool_hud_class("Task" <> _), do: "text-[#fd9000] border-[#fd9000]/30"
  defp tool_hud_class("SendMessage"), do: "text-[#fd9000] border-[#fd9000]/30"
  defp tool_hud_class("TodoWrite"), do: "text-[#fd9000] border-[#fd9000]/30"
  defp tool_hud_class("mcp__" <> _), do: "text-[#adaaaa]/40 border-[#494847]/30"
  defp tool_hud_class(_), do: "text-[#adaaaa]/40 border-[#494847]/30"

  defp short_tool_name(nil), do: ""

  defp short_tool_name("mcp__" <> rest) do
    case String.split(rest, "__", parts: 2) do
      [_server, tool] -> tool
      _ -> rest
    end
  end

  defp short_tool_name(tool), do: tool

  defp format_event_time(nil), do: ""

  defp format_event_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> String.slice(ts, 11, 8)
    end
  end

  defp format_session_duration(nil, _), do: ""
  defp format_session_duration(_, nil), do: ""

  defp format_session_duration(first, last) do
    with {:ok, f, _} <- DateTime.from_iso8601(first),
         {:ok, l, _} <- DateTime.from_iso8601(last) do
      secs = DateTime.diff(l, f)

      cond do
        secs < 60 -> "#{secs}s"
        secs < 3600 -> "#{div(secs, 60)}m"
        true -> "#{div(secs, 3600)}h #{rem(div(secs, 60), 60)}m"
      end
    else
      _ -> ""
    end
  end
end
