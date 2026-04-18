defmodule CrucibleWeb.VisualLive do
  @moduledoc """
  Visual — animated workflow execution viewer.

  Renders trace events as animated particles on a canvas overlay,
  with phase DAG and timeline structure beneath. Events replay
  sequentially with glowing trails, ripples, and flow connections.
  """

  use CrucibleWeb, :live_view

  alias Crucible.TraceReader

  @refresh_interval 10_000

  # ── Mount ──────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :refresh_runs, @refresh_interval)
    end

    {:ok,
     assign(socket,
       page_title: "Visual",
       current_path: "/visual",
       runs: [],
       selected_run: nil,
       run_detail: nil,
       manifest: %{},
       canvas_events: %{phases: [], events: [], total: 0},
       loading: true
     )}
  end

  # ── Params ─────────────────────────────────────────────────────

  @impl true
  def handle_params(%{"run_id" => run_id}, _uri, socket) do
    detail = TraceReader.detailed_run_view(run_id)
    manifest = load_raw_manifest(run_id)

    events_payload = build_canvas_events(detail, manifest)

    {:noreply,
     assign(socket,
       selected_run: run_id,
       run_detail: detail,
       manifest: manifest,
       canvas_events: events_payload
     )}
  end

  def handle_params(_params, _uri, socket) do
    runs = load_runs(socket)
    {:noreply, assign(socket, runs: runs, selected_run: nil, run_detail: nil, loading: false)}
  end

  # ── Events ─────────────────────────────────────────────────────

  @impl true
  def handle_event("select_run", %{"id" => run_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/visual/#{run_id}")}
  end

  def handle_event("replay", _params, socket) do
    if socket.assigns[:canvas_events] do
      {:noreply, push_event(socket, "visual:replay", %{events: socket.assigns.canvas_events})}
    else
      {:noreply, socket}
    end
  end

  # ── Info ────────────────────────────────────────────────────────

  @impl true
  def handle_info(:refresh_runs, socket) do
    Process.send_after(self(), :refresh_runs, @refresh_interval)
    if socket.assigns.selected_run do
      {:noreply, socket}
    else
      {:noreply, assign(socket, runs: load_runs(socket))}
    end
  end

  # ── Render ─────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-4">
        <%= if @selected_run do %>
          <.run_detail_view
            run_id={@selected_run}
            detail={@run_detail}
            manifest={@manifest}
            canvas_events={@canvas_events}
          />
        <% else %>
          <.run_list_view runs={@runs} loading={@loading} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # ── Run List ───────────────────────────────────────────────────

  defp run_list_view(assigns) do
    ~H"""
    <div class="flex justify-between items-end border-b border-[#ffa44c]/5 pb-4">
      <h1 class="text-4xl font-headline font-black text-[#ffa44c]">VISUAL</h1>
      <p class="text-[#777575] text-xs font-mono">WORKFLOW EXECUTION VIEWER</p>
    </div>

    <div :if={@loading} class="flex items-center justify-center py-20">
      <span class="text-[#777575] animate-pulse font-mono text-sm">LOADING RUNS...</span>
    </div>

    <div :if={!@loading && @runs == []} class="flex flex-col items-center justify-center py-20">
      <span class="text-[#777575] font-mono text-sm">NO RUNS FOUND</span>
    </div>

    <div :if={!@loading && @runs != []} class="space-y-1">
      <div class="grid grid-cols-[1fr_140px_100px_80px_100px] gap-2 px-4 py-2 text-[10px] text-[#777575] font-mono uppercase tracking-widest">
        <span>RUN</span>
        <span>WORKFLOW</span>
        <span>STATUS</span>
        <span>DURATION</span>
        <span>CREATED</span>
      </div>
      <button
        :for={run <- @runs}
        phx-click="select_run"
        phx-value-id={run.run_id}
        class="w-full grid grid-cols-[1fr_140px_100px_80px_100px] gap-2 px-4 py-3 text-left hover:bg-[#ffa44c]/5 transition-colors group"
      >
        <div class="min-w-0">
          <p class="text-sm text-[#e0dfde] truncate group-hover:text-[#ffa44c] transition-colors font-mono">
            <%= String.slice(run.run_id, 0..11) %>
          </p>
          <p :if={run[:task_description]} class="text-[10px] text-[#555] truncate mt-0.5">
            <%= String.slice(run[:task_description] || "", 0..80) %>
          </p>
        </div>
        <span class="text-xs text-[#777575] self-center truncate font-mono">
          <%= run[:workflow_name] || "--" %>
        </span>
        <span class="self-center">
          <.vis_status_badge status={run.status} />
        </span>
        <span class="text-xs text-[#777575] self-center font-mono">
          <%= format_duration(run[:duration_ms] || 0) %>
        </span>
        <span class="text-[10px] text-[#555] self-center font-mono">
          <%= format_ago(run[:started_at]) %>
        </span>
      </button>
    </div>
    """
  end

  # ── Run Detail ─────────────────────────────────────────────────

  defp run_detail_view(assigns) do
    summary = assigns.detail.summary
    assigns = assign(assigns, :summary, summary)

    ~H"""
    <div class="flex items-center gap-4 border-b border-[#ffa44c]/5 pb-4">
      <.link patch={~p"/visual"} class="text-[#777575] hover:text-[#ffa44c] text-sm transition-colors">
        &larr; BACK
      </.link>
      <h1 class="text-2xl font-headline font-black text-[#ffa44c]">
        <%= String.upcase(@summary[:workflow_name] || @run_id) %>
      </h1>
      <span class="text-[#555] font-mono text-xs"><%= @run_id %></span>
    </div>

    <!-- Metadata bar -->
    <div class="flex flex-wrap items-center gap-4 p-4 bg-[#131313] border border-[#494847]/20">
      <.vis_status_badge status={@manifest["status"] || @summary[:status] || "unknown"} />
      <span class="text-xs text-[#777575] font-mono">
        <%= format_duration(@summary[:duration_ms] || 0) %>
      </span>
      <span class="text-xs text-[#777575] font-mono">
        <%= length(@summary[:phases] || []) %> phases
      </span>
      <span class="text-xs text-[#777575] font-mono">
        <%= length(@detail.events) %> events
      </span>
      <button
        phx-click="replay"
        class="ml-auto text-xs text-[#777575] hover:text-[#00eefc] font-mono uppercase tracking-widest transition-colors"
      >
        ▶ REPLAY
      </button>
    </div>

    <!-- Phase DAG -->
    <.phase_dag phases={@summary[:phases] || []} />

    <!-- Animated timeline canvas -->
    <div
      id="visual-canvas-container"
      phx-hook="VisualCanvas"
      phx-update="ignore"
      data-events={Jason.encode!(@canvas_events)}
      class="bg-[#131313] border border-[#494847]/20 p-4 relative"
      style="min-height: 200px;"
    >
      <div class="text-[10px] text-[#777575] font-mono uppercase tracking-widest mb-3">
        TIMELINE
      </div>
      <canvas id="visual-canvas" class="w-full" style="height: 400px;"></canvas>
    </div>

    <!-- Event legend -->
    <div class="flex flex-wrap gap-4 px-4 py-2 text-[10px] font-mono text-[#777575]">
      <span class="flex items-center gap-1">
        <span class="w-2 h-2 rounded-full bg-[#26B5A0]"></span> Read
      </span>
      <span class="flex items-center gap-1">
        <span class="w-2 h-2 rounded-full bg-[#F2A516]"></span> Write
      </span>
      <span class="flex items-center gap-1">
        <span class="w-2 h-2 rounded-full bg-[#5940D9]"></span> Bash
      </span>
      <span class="flex items-center gap-1">
        <span class="w-2 h-2 rounded-full bg-[#F2C744]"></span> Edit
      </span>
      <span class="flex items-center gap-1">
        <span class="w-2 h-2 rounded-full bg-[#cc6666]"></span> Error
      </span>
      <span class="flex items-center gap-1">
        <span class="w-2 h-2 rounded-full bg-[#e8e4df]"></span> Other
      </span>
    </div>
    """
  end

  # ── Phase DAG component ────────────────────────────────────────

  defp phase_dag(assigns) do
    phases = assigns.phases || []
    assigns = assign(assigns, :phases, phases)

    ~H"""
    <div :if={@phases != []} class="bg-[#131313] border border-[#494847]/20 p-4">
      <div class="text-[10px] text-[#777575] font-mono uppercase tracking-widest mb-3">
        PHASE DEPENDENCIES
      </div>
      <div class="flex items-center justify-center gap-6 py-4">
        <div :for={phase <- @phases} class="flex items-center gap-4">
          <div class="relative group">
            <!-- Pulse ring -->
            <div
              :if={phase[:status] in ["completed", "done"]}
              class="absolute inset-0 rounded-full animate-ping opacity-20"
              style={"background: #{phase_color(phase[:type])}; animation-duration: 3s;"}
            />
            <!-- Node -->
            <div
              class="w-12 h-12 rounded-full flex items-center justify-center border-2 relative z-10 transition-transform group-hover:scale-110"
              style={"border-color: #{phase_color(phase[:type])}; background: #{phase_color(phase[:type])}22;"}
            >
              <span
                class="text-sm font-bold"
                style={"color: #{phase_color(phase[:type])};"}
              >
                <%= String.first(phase[:name] || "?") |> String.upcase() %>
              </span>
            </div>
            <!-- Status dot -->
            <div
              class="absolute -top-0.5 -right-0.5 w-3 h-3 rounded-full border-2 border-[#131313] z-20"
              style={"background: #{status_color(phase[:status])};"}
            />
          </div>
          <!-- Label -->
          <div class="text-center -ml-2">
            <div class="text-xs text-[#e0dfde] font-mono"><%= phase[:name] %></div>
            <div class="text-[10px] text-[#555]"><%= phase[:type] %></div>
          </div>
          <!-- Arrow (except last) -->
          <div :if={phase != List.last(@phases)} class="text-[#494847] text-lg mx-2">
            →
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Shared components ──────────────────────────────────────────

  defp vis_status_badge(assigns) do
    color = status_color(assigns.status)
    assigns = assign(assigns, :color, color)

    ~H"""
    <span
      class="inline-flex items-center gap-1.5 px-2 py-0.5 text-[10px] font-mono uppercase tracking-wider"
      style={"color: #{@color}; background: #{@color}1a;"}
    >
      <span class="w-1.5 h-1.5 rounded-full" style={"background: #{@color};"} />
      <%= @status %>
    </span>
    """
  end

  # ── Data helpers ───────────────────────────────────────────────

  defp load_runs(_socket) do
    case TraceReader.list_runs(since: week_ago()) do
      runs when is_list(runs) -> Enum.take(runs, 100)
      _ -> []
    end
  end

  defp week_ago do
    DateTime.utc_now() |> DateTime.add(-7, :day) |> DateTime.to_iso8601()
  end

  defp load_raw_manifest(run_id) do
    infra_home = Application.get_env(:crucible, :infra_home, "")
    path = Path.join([infra_home, ".claude-flow", "runs", "#{run_id}.json"])

    case File.read(path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, manifest} -> manifest
          _ -> %{}
        end

      _ ->
        TraceReader.run_manifest(run_id) || %{}
    end
  end

  defp build_canvas_events(detail, manifest) do
    phases = manifest["phases"] || []
    events = detail.events || []

    # Build phase layout info
    phase_info =
      phases
      |> Enum.with_index()
      |> Enum.map(fn {phase, idx} ->
        %{
          name: phase["phaseName"] || "phase-#{idx}",
          type: phase["type"] || "session",
          agents: phase["agents"] || [],
          depends_on: phase["dependsOn"] || [],
          status: phase["status"] || "pending",
          index: idx
        }
      end)

    # Map trace events to canvas-friendly format (events are maps with string keys)
    canvas_events =
      events
      |> Enum.filter(fn e -> e["eventType"] in ~w(tool_call mcp_tool_call) end)
      |> Enum.sort_by(& &1["timestamp"])
      |> Enum.map(fn e ->
        phase_idx = find_phase_index(e, phase_info)

        %{
          ts: to_string(e["timestamp"]),
          tool: e["tool"] || "unknown",
          agent: e["agentId"] || "default",
          phase: phase_idx,
          error: get_in(e, ["metadata", "isError"]) == true,
          detail: String.slice(e["detail"] || "", 0..60)
        }
      end)

    %{
      phases: phase_info,
      events: canvas_events,
      total: length(canvas_events)
    }
  end

  defp find_phase_index(event, phase_info) do
    phase_id = event["phaseId"]
    meta = event["metadata"] || %{}

    cond do
      is_binary(phase_id) and phase_id != "" ->
        Enum.find_index(phase_info, fn p -> p.name == phase_id end) || 0

      phase_name = meta["phaseName"] || meta["phase"] ->
        Enum.find_index(phase_info, fn p -> p.name == phase_name end) || 0

      true ->
        0
    end
  end

  # ── Formatting ─────────────────────────────────────────────────

  defp format_duration(ms) when is_number(ms) do
    cond do
      ms < 1000 -> "#{ms}ms"
      ms < 60_000 -> "#{Float.round(ms / 1000, 1)}s"
      true ->
        mins = div(trunc(ms), 60_000)
        secs = rem(trunc(ms), 60_000) |> div(1000)
        "#{mins}m #{secs}s"
    end
  end

  defp format_duration(_), do: "--"

  defp format_ago(nil), do: "--"

  defp format_ago(dt) when is_binary(dt) do
    case DateTime.from_iso8601(dt) do
      {:ok, parsed, _} -> format_ago(parsed)
      _ -> dt
    end
  end

  defp format_ago(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end

  defp format_ago(%NaiveDateTime{} = dt) do
    dt |> DateTime.from_naive!("Etc/UTC") |> format_ago()
  end

  defp format_ago(_), do: "--"

  defp phase_color("team"), do: "#F2A516"
  defp phase_color("session"), do: "#F2A516"
  defp phase_color("sprint"), do: "#F2A516"
  defp phase_color("review-gate"), do: "#26B5A0"
  defp phase_color("evaluate"), do: "#26B5A0"
  defp phase_color("pr-shepherd"), do: "#F2C744"
  defp phase_color("preflight"), do: "#7c6dd8"
  defp phase_color("scout"), do: "#7c6dd8"
  defp phase_color("api"), do: "#8b7cf7"
  defp phase_color(_), do: "#8b7cf7"

  defp status_color("completed"), do: "#00FF41"
  defp status_color("done"), do: "#00FF41"
  defp status_color("running"), do: "#ffa44c"
  defp status_color("in_progress"), do: "#ffa44c"
  defp status_color("failed"), do: "#ff725e"
  defp status_color("orphaned"), do: "#ff725e"
  defp status_color(_), do: "#777575"
end
