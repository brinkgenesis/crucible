defmodule CrucibleWeb.ControlLive do
  @moduledoc """
  Control panel — dynamic Claude Code terminal sessions.
  Only active sessions are displayed. A "+" button spawns new ones
  via a modal that asks for codebase and model. Up to 6 concurrent sessions.
  Terminal panels scale to fill available space — one session uses full width,
  two split 50/50, three form a row, etc.
  """
  use CrucibleWeb, :live_view

  alias Crucible.ControlSession
  alias CrucibleWeb.Live.RefreshTimer

  @max_slots 6
  # Default home falls back to `System.user_home!/0`, not a hardcoded user.
  defp home_dir, do: System.get_env("HOME") || System.user_home!() || "."

  @impl true
  def mount(_params, _session, socket) do
    timer =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Crucible.PubSub, "control:sessions")
        RefreshTimer.start(3_000)
      end

    slots = ControlSession.list_slots()
    models = ControlSession.available_models()
    codebases = safe_call(fn -> ControlSession.list_codebases() end, [])

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Crucible.PubSub, "voice:events")
    end

    {:ok,
     assign(socket,
       page_title: "Control",
       refresh_timer: timer,
       current_path: "/control",
       slots: slots,
       models: models,
       codebases: codebases,
       show_spawn_modal: false,
       spawn_model: "claude-sonnet-4-6",
       browse_mode: false,
       browse_path: home_dir(),
       browse_entries: [],
       input_values: %{},
       voice_log: []
     )}
  end

  @impl true
  def terminate(_reason, socket) do
    RefreshTimer.cancel(socket.assigns[:refresh_timer])
  end

  # --- Info handlers ---

  @impl true
  def handle_info({:control_updated, slots}, socket) do
    timer = RefreshTimer.reset(socket.assigns[:refresh_timer])
    {:noreply, assign(socket, slots: slots, refresh_timer: timer)}
  end

  def handle_info(:refresh, socket) do
    slots = ControlSession.list_slots()
    timer = RefreshTimer.tick(socket.assigns[:refresh_timer], true)
    {:noreply, assign(socket, slots: slots, refresh_timer: timer)}
  end

  def handle_info({:voice_command_received, %{transcript: transcript, session_id: session_id}}, socket) do
    now = DateTime.utc_now()
    timestamp = Calendar.strftime(now, "%H:%M:%S")

    entry = %{timestamp: timestamp, session_id: to_string(session_id), transcript: transcript}
    voice_log = Enum.take([entry | socket.assigns.voice_log], 10)

    {:noreply, assign(socket, voice_log: voice_log)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # --- Events ---

  @impl true
  def handle_event("open_spawn_modal", _, socket) do
    codebases = safe_call(fn -> ControlSession.list_codebases() end, socket.assigns.codebases)

    {:noreply,
     assign(socket,
       show_spawn_modal: true,
       codebases: codebases,
       browse_mode: false,
       browse_path: home_dir(),
       browse_entries: [],
       spawn_model: "claude-sonnet-4-6"
     )}
  end

  def handle_event("close_spawn_modal", _, socket) do
    {:noreply, assign(socket, show_spawn_modal: false, browse_mode: false)}
  end

  def handle_event("spawn_model_change", %{"model" => model}, socket) do
    {:noreply, assign(socket, spawn_model: model)}
  end

  def handle_event("select_codebase", %{"path" => path}, socket) do
    case next_empty_slot(socket.assigns.slots) do
      nil ->
        {:noreply, put_flash(socket, :error, "All #{@max_slots} slots are in use")}

      slot_id ->
        model = socket.assigns.spawn_model
        safe_call(fn -> ControlSession.spawn_session(slot_id, path, model: model) end, :error)
        {:noreply, assign(socket, show_spawn_modal: false, browse_mode: false)}
    end
  end

  # Folder browser events
  def handle_event("open_browser", _, socket) do
    path = home_dir()
    entries = list_directory(path)
    {:noreply, assign(socket, browse_mode: true, browse_path: path, browse_entries: entries)}
  end

  def handle_event("browse_navigate", %{"path" => path}, socket) do
    if File.dir?(path) do
      entries = list_directory(path)
      {:noreply, assign(socket, browse_path: path, browse_entries: entries)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("browse_up", _, socket) do
    parent = Path.dirname(socket.assigns.browse_path)
    entries = list_directory(parent)
    {:noreply, assign(socket, browse_path: parent, browse_entries: entries)}
  end

  def handle_event("browse_select", _, socket) do
    handle_event("select_codebase", %{"path" => socket.assigns.browse_path}, socket)
  end

  def handle_event("browse_back", _, socket) do
    {:noreply, assign(socket, browse_mode: false)}
  end

  # Active session controls
  def handle_event("change_model", %{"slot" => slot_str, "model" => model}, socket) do
    slot_id = String.to_integer(slot_str)
    safe_call(fn -> ControlSession.set_model(slot_id, model) end, :ok)

    slots =
      Enum.map(socket.assigns.slots, fn s ->
        if s.id == slot_id, do: %{s | model: model}, else: s
      end)

    {:noreply, assign(socket, slots: slots)}
  end

  def handle_event("stop_session", %{"slot" => slot_str}, socket) do
    slot_id = String.to_integer(slot_str)

    case safe_call(fn -> ControlSession.stop_session(slot_id) end, :error) do
      :error -> {:noreply, put_flash(socket, :error, "Control service unavailable")}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("send_input", %{"slot" => slot_str, "input" => text}, socket) do
    slot_id = String.to_integer(slot_str)

    case safe_call(fn -> ControlSession.send_input(slot_id, text) end, :error) do
      :error ->
        {:noreply, put_flash(socket, :error, "Control service unavailable")}

      {:error, :not_running} ->
        {:noreply, put_flash(socket, :error, "Session not running in slot #{slot_id}")}

      _ ->
        input_values = Map.put(socket.assigns.input_values, slot_id, "")
        {:noreply, assign(socket, input_values: input_values)}
    end
  end

  def handle_event("input_change", %{"slot" => slot_str, "input" => text}, socket) do
    slot_id = String.to_integer(slot_str)
    input_values = Map.put(socket.assigns.input_values, slot_id, text)
    {:noreply, assign(socket, input_values: input_values)}
  end

  def handle_event("refresh_output", %{"slot" => slot_str}, socket) do
    slot_id = String.to_integer(slot_str)
    output = safe_call(fn -> ControlSession.capture_output(slot_id) end, "")

    slots =
      Enum.map(socket.assigns.slots, fn s ->
        if s.id == slot_id, do: %{s | last_output: output}, else: s
      end)

    {:noreply, assign(socket, slots: slots)}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    # Only show sessions that are actively running or starting
    active = Enum.filter(assigns.slots, &(&1.status in [:starting, :ready]))
    active_count = length(active)
    can_spawn = active_count < @max_slots

    assigns =
      assign(assigns,
        active: active,
        active_count: active_count,
        can_spawn: can_spawn,
        max_slots: @max_slots,
        grid_class: grid_class(active_count, can_spawn),
        panel_height: panel_height(active_count)
      )

    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6 h-full">
        <%!-- Header --%>
        <div class="flex justify-between items-end border-b border-[#ffa44c]/5 pb-4">
          <div>
            <h1 class="text-4xl font-headline font-black text-[#ffa44c] tracking-tighter uppercase mb-1">SESSION_CONTROL</h1>
            <p class="font-label text-[#00eefc] text-xs uppercase tracking-[0.3em]">
              <span :if={@active_count > 0}>Active Terminal Instances: {String.pad_leading(to_string(@active_count), 2, "0")}/{String.pad_leading(to_string(@max_slots), 2, "0")}</span>
              <span :if={@active_count == 0}>NO_ACTIVE_SESSIONS // CAPACITY: {@max_slots} UNITS</span>
            </p>
          </div>
        </div>

        <%!-- Voice Command Log --%>
        <details class="bg-surface-container-low border border-[#494847]/20 group">
          <summary class="flex items-center gap-2 p-3 cursor-pointer select-none hover:bg-surface-container transition-colors">
            <span class="w-1 h-3 bg-[#00eefc]"></span>
            <span class="font-label text-[9px] text-[#00eefc] uppercase font-bold tracking-widest">RECENT_VOICE_COMMANDS</span>
            <span class="ml-auto font-label text-[9px] text-[#adaaaa]/40">
              {length(@voice_log)} entries
            </span>
          </summary>
          <div class="border-t border-[#494847]/20 p-3 space-y-1">
            <div :if={@voice_log == []} class="font-label text-[9px] text-[#adaaaa]/40 uppercase">
              NO_COMMANDS_RECEIVED
            </div>
            <div
              :for={entry <- @voice_log}
              class="font-label text-[10px] text-[#adaaaa]/80 flex gap-2 items-baseline"
            >
              <span class="text-[#00eefc]/60 shrink-0">[{entry.timestamp}]</span>
              <span class="text-[#ffa44c]/60 shrink-0">{String.slice(entry.session_id, 0, 12)}:</span>
              <span class="text-[#adaaaa]/70 truncate">{entry.transcript}</span>
            </div>
          </div>
        </details>

        <%!-- Empty state --%>
        <div :if={@active == []} class="flex flex-col items-center justify-center py-20">
          <button
            phx-click="open_spawn_modal"
            class="w-20 h-20 bg-[#ffa44c]/10 border border-[#ffa44c]/20 flex items-center justify-center hover:scale-110 transition-transform group"
            title="New session"
          >
            <span class="material-symbols-outlined text-[#ffa44c] text-4xl group-hover:text-[#00eefc] transition-colors">add</span>
          </button>
          <span class="font-headline font-bold text-sm text-[#ffa44c] tracking-widest uppercase mt-4">SPAWN_NEW_SESSION</span>
          <span class="font-label text-[9px] text-[#ffa44c]/40 mt-2 uppercase">Remaining Capacity: {String.pad_leading(to_string(@max_slots), 2, "0")} Units</span>
        </div>

        <%!-- Active sessions grid --%>
        <div :if={@active != []} class={@grid_class}>
          <.session_panel
            :for={slot <- @active}
            slot={slot}
            models={@models}
            input_value={Map.get(@input_values, slot.id, "")}
            panel_height={@panel_height}
          />

          <%!-- Spawn new session card --%>
          <button
            :if={@can_spawn}
            phx-click="open_spawn_modal"
            class={[
              "bg-surface-container-low border-2 border-dashed border-[#ffa44c]/10 flex flex-col items-center justify-center",
              "hover:border-[#ffa44c]/40 hover:bg-[#ffa44c]/5 transition-all group cursor-pointer",
              @panel_height
            ]}
            title="New session"
          >
            <div class="w-16 h-16 bg-[#ffa44c]/10 border border-[#ffa44c]/20 flex items-center justify-center mb-4 group-hover:scale-110 transition-transform">
              <span class="material-symbols-outlined text-[#ffa44c] text-4xl">add</span>
            </div>
            <span class="font-headline font-bold text-sm text-[#ffa44c] tracking-widest uppercase">SPAWN_NEW_SESSION</span>
            <span class="font-label text-[9px] text-[#ffa44c]/40 mt-2 uppercase">
              Remaining Capacity: {String.pad_leading(to_string(@max_slots - @active_count), 2, "0")} Units
            </span>
          </button>
        </div>

        <%!-- Spawn modal --%>
        <.spawn_modal
          :if={@show_spawn_modal}
          models={@models}
          spawn_model={@spawn_model}
          codebases={@codebases}
          browse_mode={@browse_mode}
          browse_path={@browse_path}
          browse_entries={@browse_entries}
        />
      </div>
    </Layouts.app>
    """
  end

  # --- Dynamic grid sizing ---
  # 1 panel  → full width, tall
  # 2 panels → 2 columns
  # 3 panels → 3 columns
  # 4+       → 3 columns (wraps to rows)
  # The "+1" for the spawn button is included in total_items count

  defp grid_class(active_count, can_spawn) do
    total = active_count + if(can_spawn, do: 1, else: 0)

    case total do
      1 -> "grid grid-cols-1 gap-3"
      2 -> "grid grid-cols-1 md:grid-cols-2 gap-3"
      3 -> "grid grid-cols-1 md:grid-cols-3 gap-3"
      _ -> "grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3"
    end
  end

  defp panel_height(active_count) do
    case active_count do
      0 -> "min-h-[500px]"
      1 -> "min-h-[500px]"
      2 -> "min-h-[420px]"
      _ -> "min-h-[320px]"
    end
  end

  # --- Session panel ---

  attr :slot, :map, required: true
  attr :models, :list, required: true
  attr :input_value, :string, required: true
  attr :panel_height, :string, required: true

  defp session_panel(assigns) do
    ~H"""
    <div class={[
      "bg-surface-container-low border flex flex-col group hover:border-[#00eefc]/40 transition-all relative",
      @panel_height,
      session_border(@slot.status)
    ]}>
      <div class={["absolute top-0 left-0 w-1 h-full", session_accent(@slot.status)]} />

      <%!-- Card Header --%>
      <div class="p-4 flex justify-between items-center bg-surface-container-high/50 border-b border-[#ffa44c]/10">
        <div class="flex items-center gap-3">
          <span class={["flex h-2 w-2", status_dot(@slot.status)]} />
          <span class="font-headline font-bold text-xs text-white tracking-widest">
            {String.upcase(Path.basename(@slot.cwd || "SESS_#{@slot.id}"))}
          </span>
          <span class={["px-2 py-0.5 font-label text-[9px] border", slot_badge_hud(@slot.status)]}>
            {String.upcase(status_label(@slot.status))}
          </span>
        </div>
        <button
          :if={@slot.status in [:ready, :starting]}
          phx-click="stop_session"
          phx-value-slot={@slot.id}
          class="text-[#ffa44c]/40 hover:text-[#ff725e] transition-colors"
        >
          <span class="material-symbols-outlined text-sm">close</span>
        </button>
      </div>

      <%!-- Terminal Output --%>
      <div
        id={"terminal-output-#{@slot.id}"}
        phx-hook="TerminalScroll"
        class="flex-1 bg-black p-4 font-label text-[11px] overflow-y-auto leading-relaxed relative"
      >
        <div
          :if={@slot.status == :starting}
          class="flex items-center justify-center h-full text-[#00eefc]/40"
        >
          <span class="text-[#00eefc] animate-pulse">[SYSTEM] Initializing session...</span>
        </div>

        <div
          :if={@slot.status == :error}
          class="flex flex-col items-center justify-center h-full gap-2"
        >
          <p class="text-[#ff725e] text-xs font-label">ERROR: {@slot.error || "UNKNOWN_FAILURE"}</p>
        </div>

        <pre
          :if={@slot.status == :ready}
          class="whitespace-pre-wrap break-words text-white/80 font-label"
        >{@slot.last_output}</pre>

        <%!-- Cursor --%>
        <span :if={@slot.status == :ready} class="animate-pulse inline-block w-2 h-4 bg-[#00eefc] ml-1"></span>

        <%!-- Refresh overlay --%>
        <button
          :if={@slot.status == :ready}
          phx-click="refresh_output"
          phx-value-slot={@slot.id}
          class="absolute top-2 right-2 text-[#ffa44c]/20 hover:text-[#ffa44c] transition-opacity"
          title="Refresh output"
        >
          <span class="material-symbols-outlined text-sm">refresh</span>
        </button>
      </div>

      <%!-- Footer Controls --%>
      <div class="p-4 bg-surface-container-high/30 space-y-4">
        <%!-- Model selector + Stop --%>
        <div :if={@slot.status in [:ready, :starting]} class="grid grid-cols-2 gap-3">
          <div class="space-y-1">
            <label class="text-[9px] text-[#ffa44c]/40 font-label tracking-tighter">MODEL_ENGINE</label>
            <select
              class="w-full bg-black border border-[#ffa44c]/20 text-[#00eefc] font-label text-[10px] p-2 focus:border-[#00eefc] outline-none"
              phx-change="change_model"
              name="model"
              phx-value-slot={@slot.id}
            >
              <option
                :for={m <- @models}
                value={m.id}
                selected={m.id == @slot.model}
              >
                {m.name}
              </option>
            </select>
          </div>
          <div class="flex items-end">
            <button
              phx-click="stop_session"
              phx-value-slot={@slot.id}
              class="w-full h-9 border border-[#ff725e]/40 text-[#ff725e] hover:bg-[#ff725e] hover:text-black transition-all font-label text-[10px] font-bold uppercase tracking-widest"
            >
              STOP_PROCESS
            </button>
          </div>
        </div>

        <%!-- Command input --%>
        <form
          :if={@slot.status == :ready}
          phx-submit="send_input"
          phx-change="input_change"
          class="relative"
        >
          <input type="hidden" name="slot" value={@slot.id} />
          <span class="absolute left-3 top-1/2 -translate-y-1/2 text-[#ffa44c] font-label text-xs font-bold">&gt;</span>
          <input
            type="text"
            name="input"
            value={@input_value}
            placeholder="ENTER_COMMAND..."
            class="w-full bg-black border border-[#ffa44c]/10 pl-8 pr-4 py-2 text-white font-label text-xs placeholder:text-[#ffa44c]/20 focus:border-[#ffa44c] outline-none transition-all"
            autocomplete="off"
          />
        </form>

        <%!-- Session info --%>
        <div
          :if={@slot.started_at}
          class="text-[9px] text-[#ffa44c]/30 flex items-center gap-2 font-label"
        >
          <span>{@slot.tmux_session}</span>
          <span class="text-[#ffa44c]/10">|</span>
          <span>{format_elapsed(@slot.started_at)}</span>
        </div>
      </div>
    </div>
    """
  end

  # --- Spawn modal ---

  attr :models, :list, required: true
  attr :spawn_model, :string, required: true
  attr :codebases, :list, required: true
  attr :browse_mode, :boolean, required: true
  attr :browse_path, :string, required: true
  attr :browse_entries, :list, required: true

  defp spawn_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-end sm:items-center justify-center">
      <div class="fixed inset-0 bg-black/60 backdrop-blur-sm" phx-click="close_spawn_modal"></div>
      <div class="fixed bottom-12 right-12 w-80 bg-surface-container-high border border-[#ffa44c]/40 p-6 z-50 shadow-[0_0_20px_rgba(255,164,76,0.15)]">
        <div class="flex justify-between items-center mb-6 border-b border-[#ffa44c]/20 pb-2">
          <h2 class="font-headline font-bold text-[#ffa44c] text-sm uppercase tracking-widest flex items-center gap-2">
            <span class="material-symbols-outlined text-lg">rocket_launch</span> SPAWN_PARAM
          </h2>
          <button phx-click="close_spawn_modal" class="text-[#ffa44c]/40 hover:text-[#ffa44c] transition-colors">
            <span class="material-symbols-outlined text-sm">close</span>
          </button>
        </div>

        <div class="space-y-6">
          <%!-- Model selector --%>
          <div class="space-y-2">
            <label class="text-[10px] text-[#ffa44c]/60 font-label font-bold block">MODEL_SELECTOR</label>
            <div class="grid grid-cols-1 gap-2">
              <label
                :for={m <- @models}
                class="flex items-center gap-3 p-2 border border-[#ffa44c]/10 hover:bg-[#ffa44c]/5 cursor-pointer"
              >
                <input
                  type="radio"
                  name="model"
                  value={m.id}
                  checked={m.id == @spawn_model}
                  phx-click="spawn_model_change"
                  phx-value-model={m.id}
                  class="text-[#ffa44c] bg-black border-[#ffa44c]/30 focus:ring-0 focus:ring-offset-0"
                />
                <span class="font-label text-[10px] text-white">{m.name}</span>
              </label>
            </div>
          </div>

          <%!-- Codebase picker --%>
          <div class="space-y-2">
            <label class="text-[10px] text-[#ffa44c]/60 font-label font-bold block">CODEBASE_PATH</label>

            <%= if @browse_mode do %>
              <div class="space-y-2">
                <div class="flex items-center gap-1 bg-black p-2 border border-[#ffa44c]/10">
                  <button phx-click="browse_back" class="text-[#ffa44c]/40 hover:text-[#ffa44c] p-1" title="Back">
                    <span class="material-symbols-outlined text-sm">arrow_back</span>
                  </button>
                  <button phx-click="browse_up" class="text-[#ffa44c]/40 hover:text-[#ffa44c] p-1" title="Up">
                    <span class="material-symbols-outlined text-sm">arrow_upward</span>
                  </button>
                  <span class="font-label text-[9px] text-white/60 truncate flex-1" title={@browse_path}>
                    {@browse_path}
                  </span>
                </div>

                <div class="space-y-0.5 max-h-[200px] overflow-y-auto border border-[#ffa44c]/10 p-1">
                  <div :if={@browse_entries == []} class="text-center text-[9px] text-white/30 font-label py-4">
                    NO_SUBDIRECTORIES
                  </div>
                  <button
                    :for={entry <- @browse_entries}
                    phx-click="browse_navigate"
                    phx-value-path={entry.path}
                    class="w-full text-left px-2 py-1.5 hover:bg-[#ffa44c]/5 transition-colors flex items-center gap-2"
                  >
                    <span class={["material-symbols-outlined text-sm", entry_icon_color(entry)]}>
                      {if entry.is_git, do: "code", else: "folder"}
                    </span>
                    <span class="text-xs text-white/80 truncate font-label">{entry.name}</span>
                    <span :if={entry.is_git} class="ml-auto text-[8px] font-label text-[#00eefc] border border-[#00eefc]/20 px-1">GIT</span>
                  </button>
                </div>

                <button
                  phx-click="browse_select"
                  class="w-full bg-[#ffa44c] text-black font-headline font-black py-3 text-xs tracking-widest uppercase hover:bg-[#00eefc] transition-all"
                >
                  SELECT_PATH
                </button>
              </div>
            <% else %>
              <div class="space-y-1 max-h-[200px] overflow-y-auto">
                <button
                  :for={cb <- @codebases}
                  phx-click="select_codebase"
                  phx-value-path={cb.path}
                  class="w-full text-left p-2 hover:bg-[#ffa44c]/5 transition-colors border border-transparent hover:border-[#ffa44c]/20 flex items-center gap-3"
                >
                  <span class="material-symbols-outlined text-[#ffa44c]/40 text-sm">folder</span>
                  <div class="min-w-0">
                    <div class="font-bold text-xs text-white truncate font-headline">{cb.name}</div>
                    <div class="text-[9px] text-white/40 font-label truncate">{cb.path}</div>
                  </div>
                </button>
              </div>

              <div class="border-t border-[#ffa44c]/10 pt-3 mt-3">
                <button phx-click="open_browser" class="w-full border border-[#ffa44c]/30 text-[#ffa44c] font-label text-[10px] uppercase tracking-widest py-2 hover:bg-[#ffa44c]/10 transition-colors">
                  <span class="material-symbols-outlined text-sm align-middle mr-1">folder_open</span> BROWSE_FOLDERS
                </button>
              </div>
            <% end %>
          </div>

          <button
            :if={!@browse_mode}
            phx-click="close_spawn_modal"
            class="w-full bg-[#ffa44c] text-black font-headline font-black py-3 text-xs tracking-widest uppercase hover:bg-[#00eefc] transition-all"
          >
            INITIATE_SPAWN
          </button>
        </div>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp next_empty_slot(slots) do
    case Enum.find(slots, &(&1.status == :empty)) do
      nil -> nil
      slot -> slot.id
    end
  end

  defp session_border(:ready), do: "border-[#ffa44c]/20"
  defp session_border(:starting), do: "border-[#ffa44c]/20 animate-pulse"
  defp session_border(:error), do: "border-[#ff725e]/30"
  defp session_border(_), do: "border-[#ffa44c]/10"

  defp session_accent(:ready), do: "bg-[#ffa44c]/20 group-hover:bg-[#00eefc]/50"
  defp session_accent(:starting), do: "bg-[#ffa44c]/40 animate-pulse"
  defp session_accent(:error), do: "bg-[#ff725e]/50"
  defp session_accent(_), do: "bg-[#ffa44c]/10"

  defp status_dot(:ready), do: "bg-[#00eefc] animate-pulse rounded-full"
  defp status_dot(:starting), do: "bg-[#ffa44c] animate-pulse rounded-full"
  defp status_dot(:error), do: "bg-[#ff725e] rounded-full"
  defp status_dot(_), do: "bg-[#ffa44c]/30 rounded-full"

  defp slot_badge_hud(:ready), do: "bg-[#00eefc]/10 text-[#00eefc] border-[#00eefc]/20"
  defp slot_badge_hud(:starting), do: "bg-[#ffa44c]/10 text-[#ffa44c] border-[#ffa44c]/20"
  defp slot_badge_hud(:error), do: "bg-[#ff725e]/10 text-[#ff725e] border-[#ff725e]/20"
  defp slot_badge_hud(_), do: "bg-[#ffa44c]/10 text-[#ffa44c]/60 border-[#ffa44c]/20"

  defp status_label(:ready), do: "running"
  defp status_label(:starting), do: "starting"
  defp status_label(:error), do: "error"
  defp status_label(_), do: "idle"

  defp format_elapsed(nil), do: ""

  defp format_elapsed(%DateTime{} = started_at) do
    secs = DateTime.diff(DateTime.utc_now(), started_at)

    cond do
      secs < 60 -> "#{secs}s"
      secs < 3600 -> "#{div(secs, 60)}m"
      true -> "#{div(secs, 3600)}h #{rem(div(secs, 60), 60)}m"
    end
  end

  defp format_elapsed(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> format_elapsed(dt)
      _ -> ""
    end
  end

  defp format_elapsed(_), do: ""

  defp list_directory(path) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.map(fn name ->
          full = Path.join(path, name)

          %{
            name: name,
            path: full,
            is_dir: File.dir?(full),
            is_git: File.exists?(Path.join(full, ".git"))
          }
        end)
        |> Enum.filter(& &1.is_dir)
        |> Enum.sort_by(fn e -> {!e.is_git, e.name} end)

      _ ->
        []
    end
  end

  defp entry_icon_color(%{is_git: true}), do: "text-[#00eefc]"
  defp entry_icon_color(_), do: "text-[#ffa44c]/40"
end
