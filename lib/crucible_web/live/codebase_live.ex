defmodule CrucibleWeb.CodebaseLive do
  @moduledoc """
  LiveView for codebase exploration and intelligence.

  Provides three view modes for navigating indexed codebase data:

    * **List** — tabular view of modules with dependency, symbol, and export counts.
      Supports prefix filtering and text search.
    * **Graph** — force-directed dependency graph rendered via the `ForceGraph` JS hook.
    * **Intelligence** — analytical queries (hotspots, symbol lookup, cross-reference search)
      powered by `Crucible.CodebaseReader`.

  Data is auto-refreshed every 30 seconds via `RefreshTimer`. Multiple projects
  are supported and selectable from the UI when more than one is indexed.
  """

  use CrucibleWeb, :live_view

  alias CrucibleWeb.Live.RefreshTimer

  alias Crucible.CodebaseReader

  @refresh_interval 30_000
  @valid_views ~w(list graph intelligence)

  @doc """
  Initializes the LiveView with default assigns and loads codebase data.

  Sets the default project to `"infra"` if available, starts the refresh timer
  for connected clients, and loads module/stat/prefix data for the initial view.
  """
  @impl true
  def mount(_params, _session, socket) do
    timer = if connected?(socket), do: RefreshTimer.start(@refresh_interval)

    projects = CodebaseReader.list_projects()
    project = if "infra" in projects, do: "infra", else: List.first(projects, "infra")

    {:ok,
     assign(socket,
       page_title: "Codebase",
       refresh_timer: timer,
       current_path: "/codebase",
       project: project,
       projects: projects,
       view_mode: "list",
       search: "",
       filter_prefix: nil,
       selected_module: nil,
       module_detail: nil,
       graph_data: %{nodes: [], edges: []},
       intel_type: nil,
       intel_file: "",
       intel_symbol: "",
       intel_results: nil,
       intel_error: nil,
       intel_loading: false
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
  Handles the periodic `:refresh` message by reloading codebase data and rescheduling the timer.
  """
  @impl true
  def handle_info(:refresh, socket) do
    socket = load_data(socket)
    timer = RefreshTimer.tick(socket.assigns[:refresh_timer], true)
    {:noreply, assign(socket, refresh_timer: timer)}
  end

  @doc """
  Applies the `view` query parameter (list, graph, or intelligence) to the socket.

  Falls back to the current view mode or `"list"` if the parameter is invalid.
  """
  @impl true
  def handle_params(params, _uri, socket) do
    view = normalize_view_mode(Map.get(params, "view"), socket.assigns[:view_mode] || "list")
    {:noreply, apply_view_mode(socket, view)}
  end

  @doc """
  Handles all UI events for the codebase explorer.

  Supported events:

    * `"switch_view"` — navigates between list, graph, and intelligence views via `push_patch`.
    * `"filter_prefix"` — toggles a directory prefix filter; reloads graph data if in graph view.
    * `"search"` — filters the module list by a case-insensitive substring match.
    * `"select_note"` / `"select_module"` — selects a module and loads its detail panel
      (dependencies, dependents, symbols, and vault note).
    * `"switch_project"` — switches to a different indexed project and resets filters.
    * `"clear_selection"` — dismisses the module detail panel.
    * `"set_intel_type"` — switches the intelligence query type (hotspots, symbols, references).
    * `"run_intel_query"` — executes an intelligence query with the current parameters.
  """
  @impl true
  def handle_event("switch_view", %{"view" => view}, socket) do
    view = normalize_view_mode(view, socket.assigns.view_mode)
    {:noreply, push_patch(socket, to: codebase_path(view))}
  end

  def handle_event("filter_prefix", %{"prefix" => prefix}, socket) do
    prefix = if prefix == "", do: nil, else: prefix
    current = socket.assigns.filter_prefix
    new_prefix = if current == prefix, do: nil, else: prefix

    socket = assign(socket, filter_prefix: new_prefix, selected_module: nil, module_detail: nil)

    socket =
      if socket.assigns.view_mode == "graph" do
        graph_data = build_graph_data(socket.assigns.project, new_prefix)
        assign(socket, graph_data: graph_data)
      else
        socket
      end

    {:noreply, load_data(socket)}
  end

  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, assign(socket, search: search) |> load_data()}
  end

  def handle_event("select_note", %{"path" => path}, socket) do
    select_module(path, socket)
  end

  def handle_event("select_module", %{"path" => path}, socket) do
    select_module(path, socket)
  end

  def handle_event("switch_project", %{"project" => project}, socket) do
    {:noreply,
     assign(socket,
       project: project,
       filter_prefix: nil,
       selected_module: nil,
       module_detail: nil,
       search: ""
     )
     |> load_data()}
  end

  def handle_event("clear_selection", _, socket) do
    {:noreply, assign(socket, selected_module: nil, module_detail: nil)}
  end

  def handle_event("set_intel_type", %{"type" => type}, socket) do
    intel_type = safe_intel_atom(type)
    {:noreply, assign(socket, intel_type: intel_type, intel_results: nil, intel_error: nil)}
  end

  def handle_event("run_intel_query", params, socket) do
    file = Map.get(params, "file", socket.assigns.intel_file)
    symbol = Map.get(params, "symbol", socket.assigns.intel_symbol)

    socket = assign(socket, intel_loading: true, intel_file: file, intel_symbol: symbol)

    result =
      fetch_intel(socket.assigns.intel_type, socket.assigns.project, %{
        file: file,
        symbol: symbol
      })

    case result do
      {:ok, data} ->
        {:noreply, assign(socket, intel_results: data, intel_error: nil, intel_loading: false)}

      {:error, reason} ->
        {:noreply, assign(socket, intel_error: reason, intel_results: nil, intel_loading: false)}
    end
  end

  defp select_module(path, socket) do
    if socket.assigns.selected_module == path do
      {:noreply, assign(socket, selected_module: nil, module_detail: nil)}
    else
      detail = CodebaseReader.get_module(path, socket.assigns.project)
      dependents = CodebaseReader.dependents(path, socket.assigns.project)

      note =
        if detail do
          CodebaseReader.read_module_note(detail.slug, socket.assigns.project)
        end

      {:noreply,
       assign(socket,
         selected_module: path,
         module_detail: detail && Map.merge(detail, %{dependents: dependents, note: note})
       )}
    end
  end

  # ---------------------------------------------------------------------------
  # Data loading
  # ---------------------------------------------------------------------------

  defp load_data(socket) do
    project = socket.assigns.project
    stats = CodebaseReader.dependency_stats(project)
    prefixes = CodebaseReader.directory_prefixes(project)
    modules = load_filtered_modules(project, socket.assigns)

    assign(socket,
      modules: modules,
      stats: stats,
      prefixes: prefixes
    )
  end

  defp load_filtered_modules(project, assigns) do
    modules = CodebaseReader.list_modules(project)

    modules =
      if assigns.filter_prefix do
        Enum.filter(modules, &String.starts_with?(&1.path, assigns.filter_prefix))
      else
        modules
      end

    if assigns.search != "" do
      q = String.downcase(assigns.search)
      Enum.filter(modules, &String.contains?(String.downcase(&1.path), q))
    else
      modules
    end
  end

  defp build_graph_data(project, prefix) do
    opts = if prefix, do: [prefix: prefix], else: []
    CodebaseReader.build_graph(project, opts)
  end

  defp apply_view_mode(socket, "graph") do
    graph_data = build_graph_data(socket.assigns.project, socket.assigns.filter_prefix)
    assign(socket, view_mode: "graph", graph_data: graph_data)
  end

  defp apply_view_mode(socket, "intelligence") do
    socket
    |> assign(view_mode: "intelligence", intel_error: nil)
    |> maybe_set_default_intel_type()
  end

  defp apply_view_mode(socket, _view) do
    assign(socket, view_mode: "list")
  end

  defp maybe_set_default_intel_type(%{assigns: %{intel_type: nil}} = socket),
    do: assign(socket, intel_type: :hotspots, intel_results: nil)

  defp maybe_set_default_intel_type(socket), do: socket

  defp normalize_view_mode(view, _fallback) when view in @valid_views, do: view
  defp normalize_view_mode(_view, fallback) when fallback in @valid_views, do: fallback
  defp normalize_view_mode(_view, _fallback), do: "list"

  defp codebase_path(view), do: "/codebase?view=#{view}"

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @doc """
  Renders the codebase intelligence page.

  The template includes stat cards (modules, edges, top importer, last indexed),
  view mode controls, project selector, search input, prefix filter pills, and
  the active view panel (list table, force-directed graph, or intelligence query UI).
  A module detail panel is shown when a module is selected.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <.hud_header icon="code" label="CODEBASE_INTELLIGENCE" />
        
    <!-- Stat cards -->
        <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
          <.hud_card>
            <.hud_stat label="MODULES" value={to_string(@stats.total_modules)} color="primary" />
          </.hud_card>
          <.hud_card>
            <.hud_stat label="EDGES" value={to_string(@stats.total_edges)} color="secondary" />
          </.hud_card>
          <.hud_card>
            <.hud_stat label="TOP IMPORTER" value={@stats.top_importer} color="tertiary" />
          </.hud_card>
          <.hud_card>
            <.hud_stat label="LAST INDEXED" value={@stats.last_indexed} color="primary" />
          </.hud_card>
        </div>
        
    <!-- Controls -->
        <div class="flex flex-wrap items-center gap-3 bg-surface-container-low hud-border p-3">
          <!-- View toggle -->
          <div class="flex border border-[#ffa44c]/20 rounded overflow-hidden">
            <button
              :for={
                {view, label, icon} <- [
                  {"list", "LIST", "view_list"},
                  {"graph", "GRAPH", "hub"},
                  {"intelligence", "INTEL", "psychology"}
                ]
              }
              phx-click="switch_view"
              phx-value-view={view}
              class={[
                "flex items-center gap-1 px-3 py-1.5 font-mono text-[9px] tracking-widest uppercase transition-colors",
                if(@view_mode == view,
                  do: "bg-[#ffa44c] text-black",
                  else: "text-[#e0e0e0]/40 hover:text-[#e0e0e0]/60 hover:bg-[#ffa44c]/10"
                )
              ]}
            >
              <span class="material-symbols-outlined text-xs">{icon}</span>
              {label}
            </button>
          </div>
          
    <!-- Project selector -->
          <select
            :if={length(@projects) > 1}
            phx-change="switch_project"
            name="project"
            class="bg-surface-container border border-[#ffa44c]/20 text-[#e0e0e0] font-mono text-[11px] px-2 py-1.5 rounded focus:border-[#00eefc]/50 focus:outline-none"
          >
            <option :for={p <- @projects} value={p} selected={p == @project}>{p}</option>
          </select>
          
    <!-- Search -->
          <form phx-change="search" class="flex-1 max-w-xs">
            <input
              type="text"
              name="search"
              value={@search}
              placeholder="Search modules…"
              phx-debounce="300"
              class="w-full bg-surface-container border border-[#ffa44c]/20 text-[#e0e0e0] font-mono text-[11px] px-3 py-1.5 rounded focus:border-[#00eefc]/50 focus:outline-none placeholder:text-[#e0e0e0]/20"
            />
          </form>

          <span class="font-mono text-[10px] text-[#ffa44c]/40 ml-auto">
            {length(@modules)} modules
          </span>
        </div>
        
    <!-- Prefix filter pills -->
        <div :if={@prefixes != []} class="flex flex-wrap gap-1">
          <button
            :for={prefix <- Enum.take(@prefixes, 12)}
            phx-click="filter_prefix"
            phx-value-prefix={prefix}
            class={[
              "px-2 py-0.5 font-mono text-[9px] tracking-wider uppercase rounded border transition-colors cursor-pointer",
              if(@filter_prefix == prefix,
                do: "bg-[#ffa44c] text-black border-[#ffa44c]",
                else:
                  "text-[#e0e0e0]/40 border-[#e0e0e0]/10 hover:border-[#ffa44c]/30 hover:text-[#e0e0e0]/60"
              )
            ]}
          >
            {prefix}
          </button>
          <button
            :if={@filter_prefix}
            phx-click="filter_prefix"
            phx-value-prefix=""
            class="px-2 py-0.5 font-mono text-[9px] tracking-wider uppercase rounded border border-[#ff725e]/30 text-[#ff725e]/60 hover:text-[#ff725e] cursor-pointer transition-colors"
          >
            CLEAR
          </button>
        </div>
        
    <!-- List view -->
        <div :if={@view_mode == "list"}>
          <.hud_card>
            <div class="overflow-x-auto">
              <table class="w-full">
                <thead>
                  <tr class="border-b border-[#ffa44c]/10">
                    <th class="text-left font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-2 px-3">
                      Module
                    </th>
                    <th class="text-right font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-2 px-3">
                      Deps
                    </th>
                    <th class="text-right font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-2 px-3">
                      Symbols
                    </th>
                    <th class="text-right font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-2 px-3">
                      Exported
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={mod <- Enum.take(@modules, 200)}
                    phx-click="select_module"
                    phx-value-path={mod.path}
                    class={[
                      "border-b border-[#ffa44c]/5 hover:bg-[#ffa44c]/5 cursor-pointer transition-colors",
                      @selected_module == mod.path && "bg-[#ffa44c]/10 border-l-2 border-l-[#ffa44c]"
                    ]}
                  >
                    <td class="font-mono text-[11px] text-[#00eefc] py-2 px-3">{mod.path}</td>
                    <td class="text-right font-mono text-[11px] text-[#e0e0e0]/50 py-2 px-3">
                      {mod.dep_count}
                    </td>
                    <td class="text-right font-mono text-[11px] text-[#e0e0e0]/50 py-2 px-3">
                      {mod.symbol_count}
                    </td>
                    <td class="text-right font-mono text-[11px] text-[#e0e0e0]/50 py-2 px-3">
                      {mod.exported_count}
                    </td>
                  </tr>
                </tbody>
              </table>
              <div
                :if={length(@modules) > 200}
                class="font-mono text-[10px] text-[#ffa44c]/40 mt-3 text-center"
              >
                SHOWING 200 OF {length(@modules)} — USE SEARCH OR FILTER TO NARROW
              </div>
            </div>
          </.hud_card>
        </div>
        
    <!-- Graph view -->
        <div
          :if={@view_mode == "graph"}
          id="codebase-graph"
          phx-hook="ForceGraph"
          phx-update="ignore"
          data-graph={Jason.encode!(@graph_data)}
          class="w-full h-[600px] bg-surface-container-low hud-border rounded"
        >
        </div>
        
    <!-- Intelligence view -->
        <div :if={@view_mode == "intelligence"} class="space-y-4">
          <!-- Query type tabs -->
          <div class="flex border border-[#00eefc]/20 rounded overflow-hidden w-fit">
            <button
              :for={
                {label, type} <- [
                  {"HOTSPOTS", "hotspots"},
                  {"SYMBOLS", "symbols"},
                  {"REFERENCES", "references"}
                ]
              }
              phx-click="set_intel_type"
              phx-value-type={type}
              class={[
                "px-3 py-1.5 font-mono text-[9px] tracking-widest uppercase transition-colors",
                if(@intel_type == String.to_atom(type),
                  do: "bg-[#00eefc] text-black",
                  else: "text-[#e0e0e0]/40 hover:text-[#00eefc]/60 hover:bg-[#00eefc]/10"
                )
              ]}
            >
              {label}
            </button>
          </div>
          
    <!-- Input fields -->
          <form phx-submit="run_intel_query" class="flex gap-2 items-center">
            <input
              :if={@intel_type == :symbols}
              type="text"
              name="file"
              value={@intel_file}
              placeholder="File path (e.g. lib/router/index.ts)"
              class="flex-1 bg-surface-container border border-[#ffa44c]/20 text-[#e0e0e0] font-mono text-[11px] px-3 py-1.5 rounded focus:border-[#00eefc]/50 focus:outline-none placeholder:text-[#e0e0e0]/20"
            />
            <input
              :if={@intel_type == :references}
              type="text"
              name="symbol"
              value={@intel_symbol}
              placeholder="Symbol name (e.g. routeRequest)"
              class="flex-1 bg-surface-container border border-[#ffa44c]/20 text-[#e0e0e0] font-mono text-[11px] px-3 py-1.5 rounded focus:border-[#00eefc]/50 focus:outline-none placeholder:text-[#e0e0e0]/20"
            />
            <.tactical_button variant="primary" type="submit" disabled={@intel_loading}>
              <span
                :if={@intel_loading}
                class="inline-block w-3 h-3 border-2 border-[#ffa44c]/30 border-t-[#ffa44c] rounded-full animate-spin mr-1"
              />
              {if @intel_type == :hotspots, do: "LOAD HOTSPOTS", else: "SEARCH"}
            </.tactical_button>
          </form>
          
    <!-- Error state -->
          <div
            :if={@intel_error}
            class="flex items-center gap-3 px-4 py-2.5 font-mono text-xs text-[#ff7351] border border-[#ff7351]/20 bg-[#ff7351]/5 rounded"
          >
            <span class="material-symbols-outlined text-sm">error</span>
            <span>{@intel_error}</span>
          </div>
          
    <!-- Results -->
          <div :if={@intel_results}>
            <.hud_card>
              <!-- Hotspots results (list) -->
              <div :if={@intel_type == :hotspots && is_list(@intel_results)}>
                <div class="font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 mb-3">
                  TOP FILES BY COMPLEXITY
                </div>
                <table class="w-full">
                  <thead>
                    <tr class="border-b border-[#ffa44c]/10">
                      <th class="text-left font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-1.5 px-2">
                        File
                      </th>
                      <th class="text-right font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-1.5 px-2">
                        Syms
                      </th>
                      <th class="text-right font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-1.5 px-2">
                        Exp
                      </th>
                      <th class="text-right font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-1.5 px-2">
                        Deps
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={item <- Enum.take(@intel_results, 20)}
                      class="border-b border-[#ffa44c]/5 hover:bg-[#ffa44c]/5"
                    >
                      <td class="font-mono text-[11px] py-1.5 px-2">
                        <button
                          phx-click="select_module"
                          phx-value-path={item["path"] || item["file"]}
                          class="text-[#00eefc] hover:text-[#00eefc]/80 text-left"
                        >
                          {item["path"] || item["file"]}
                        </button>
                      </td>
                      <td class="text-right font-mono text-[11px] text-[#e0e0e0]/50 py-1.5 px-2">
                        {item["symbolCount"] || item["symbols"] || "—"}
                      </td>
                      <td class="text-right font-mono text-[11px] text-[#e0e0e0]/50 py-1.5 px-2">
                        {item["exportedCount"] || item["exports"] || "—"}
                      </td>
                      <td class="text-right font-mono text-[11px] text-[#e0e0e0]/50 py-1.5 px-2">
                        {item["depCount"] || item["deps"] || "—"}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
              
    <!-- Hotspots results (map / health endpoint) -->
              <div :if={@intel_type == :hotspots && is_map(@intel_results)} class="space-y-2">
                <div class="font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 mb-3">
                  CODEBASE HEALTH
                </div>
                <div
                  :for={{key, val} <- @intel_results}
                  :if={is_binary(key)}
                  class="flex justify-between py-1 border-b border-[#ffa44c]/5"
                >
                  <span class="font-mono text-[11px] text-[#e0e0e0]/50 capitalize">
                    {key |> String.replace("_", " ")}
                  </span>
                  <span class="font-mono text-[11px] text-[#00eefc]">{inspect(val)}</span>
                </div>
              </div>
              
    <!-- Symbols results -->
              <div :if={@intel_type == :symbols}>
                <div class="font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 mb-3">
                  SYMBOLS
                </div>
                <table class="w-full">
                  <thead>
                    <tr class="border-b border-[#ffa44c]/10">
                      <th class="text-left font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-1.5 px-2">
                        Name
                      </th>
                      <th class="text-left font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-1.5 px-2">
                        Kind
                      </th>
                      <th class="text-left font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-1.5 px-2">
                        Line
                      </th>
                      <th class="text-left font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-1.5 px-2">
                        Exp
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={sym <- List.wrap(@intel_results)}
                      class="border-b border-[#ffa44c]/5 hover:bg-[#ffa44c]/5"
                    >
                      <td class="font-mono text-[11px] text-[#e0e0e0]/70 py-1.5 px-2">
                        {sym["name"]}
                      </td>
                      <td class="py-1.5 px-2">
                        <span class={[
                          "px-1.5 py-0.5 font-mono text-[8px] font-bold uppercase border rounded",
                          kind_hud_badge(sym["kind"])
                        ]}>
                          {sym["kind"]}
                        </span>
                      </td>
                      <td class="font-mono text-[11px] text-[#e0e0e0]/40 py-1.5 px-2">
                        {sym["line"] || "—"}
                      </td>
                      <td class="py-1.5 px-2">
                        <span :if={sym["exported"]} class="text-[#00FF41] text-[10px]">✓</span>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
              
    <!-- References results -->
              <div :if={@intel_type == :references}>
                <div class="font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 mb-3">
                  REFERENCES
                </div>
                <table class="w-full">
                  <thead>
                    <tr class="border-b border-[#ffa44c]/10">
                      <th class="text-left font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-1.5 px-2">
                        File
                      </th>
                      <th class="text-left font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-1.5 px-2">
                        Line
                      </th>
                      <th class="text-left font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-1.5 px-2">
                        Context
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={ref <- List.wrap(@intel_results)}
                      class="border-b border-[#ffa44c]/5 hover:bg-[#ffa44c]/5"
                    >
                      <td class="font-mono text-[11px] py-1.5 px-2">
                        <button
                          phx-click="select_module"
                          phx-value-path={ref["file"]}
                          class="text-[#00eefc] hover:text-[#00eefc]/80 text-left"
                        >
                          {ref["file"]}
                        </button>
                      </td>
                      <td class="font-mono text-[11px] text-[#e0e0e0]/40 py-1.5 px-2">
                        {ref["line"] || "—"}
                      </td>
                      <td class="font-mono text-[11px] text-[#e0e0e0]/30 max-w-xs truncate py-1.5 px-2">
                        {ref["context"] || ref["snippet"] || ""}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>

              <div
                :if={@intel_results == []}
                class="text-center py-4 text-[#e0e0e0]/30 font-mono text-xs"
              >
                NO_RESULTS_FOUND
              </div>
            </.hud_card>
          </div>
        </div>
        
    <!-- Module detail panel -->
        <div :if={@selected_module && @module_detail}>
          <.hud_card accent="secondary">
            <div class="flex items-start justify-between">
              <div>
                <h3 class="font-mono text-sm font-bold text-[#00eefc]">{@module_detail.path}</h3>
                <span class="font-mono text-[10px] text-[#e0e0e0]/30">
                  slug: {@module_detail.slug}
                </span>
              </div>
              <button
                phx-click="clear_selection"
                class="px-2 py-1 text-[#e0e0e0]/30 hover:text-[#ff725e] hover:bg-[#ff725e]/10 rounded transition-colors"
              >
                <span class="material-symbols-outlined text-sm">close</span>
              </button>
            </div>
            
    <!-- Purpose from vault note -->
            <div
              :if={@module_detail.note}
              class="mt-3 p-3 bg-surface-container rounded border border-[#ffa44c]/10 font-mono text-[11px] text-[#e0e0e0]/60"
            >
              {@module_detail.note}
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mt-4">
              <!-- Dependencies -->
              <div>
                <div class="font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 mb-2">
                  DEPENDENCIES ({@module_detail.dep_count})
                </div>
                <div class="space-y-1 max-h-48 overflow-y-auto">
                  <div
                    :for={edge <- @module_detail.edges}
                    class="flex items-center gap-2"
                  >
                    <span class="px-1 py-0.5 font-mono text-[8px] uppercase text-[#ffa44c]/40 border border-[#ffa44c]/10 rounded">
                      {edge.type}
                    </span>
                    <button
                      phx-click="select_module"
                      phx-value-path={edge.target}
                      class="font-mono text-[11px] text-[#00eefc] hover:text-[#00eefc]/80 truncate"
                    >
                      {edge.target}
                    </button>
                    <span
                      :if={edge.names != []}
                      class="font-mono text-[10px] text-[#e0e0e0]/20 truncate"
                    >
                      {Enum.join(edge.names, ", ")}
                    </span>
                  </div>
                  <div
                    :if={@module_detail.edges == []}
                    class="font-mono text-[11px] text-[#e0e0e0]/20"
                  >
                    No dependencies
                  </div>
                </div>
              </div>
              
    <!-- Dependents -->
              <div>
                <div class="font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 mb-2">
                  DEPENDENTS ({length(@module_detail.dependents)})
                </div>
                <div class="space-y-1 max-h-48 overflow-y-auto">
                  <button
                    :for={dep <- @module_detail.dependents}
                    phx-click="select_module"
                    phx-value-path={dep}
                    class="block font-mono text-[11px] text-[#00eefc] hover:text-[#00eefc]/80 truncate"
                  >
                    {dep}
                  </button>
                  <div
                    :if={@module_detail.dependents == []}
                    class="font-mono text-[11px] text-[#e0e0e0]/20"
                  >
                    No dependents
                  </div>
                </div>
              </div>
            </div>
            
    <!-- Symbols -->
            <div :if={@module_detail.symbols != []} class="mt-4">
              <div class="font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 mb-2">
                SYMBOLS ({@module_detail.symbol_count})
              </div>
              <div class="overflow-x-auto max-h-64 overflow-y-auto">
                <table class="w-full">
                  <thead>
                    <tr class="border-b border-[#ffa44c]/10">
                      <th class="text-left font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-1.5 px-2">
                        Name
                      </th>
                      <th class="text-left font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-1.5 px-2">
                        Kind
                      </th>
                      <th class="text-left font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-1.5 px-2">
                        Exp
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={sym <- @module_detail.symbols} class="border-b border-[#ffa44c]/5">
                      <td class="font-mono text-[11px] text-[#e0e0e0]/70 py-1.5 px-2">{sym.name}</td>
                      <td class="py-1.5 px-2">
                        <span class={[
                          "px-1.5 py-0.5 font-mono text-[8px] font-bold uppercase border rounded",
                          kind_hud_badge(sym.kind)
                        ]}>
                          {sym.kind}
                        </span>
                      </td>
                      <td class="py-1.5 px-2">
                        <span :if={sym.exported} class="text-[#00FF41] text-[10px]">✓</span>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </.hud_card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Intelligence
  # ---------------------------------------------------------------------------

  defp safe_intel_atom("hotspots"), do: :hotspots
  defp safe_intel_atom("symbols"), do: :symbols
  defp safe_intel_atom("references"), do: :references
  defp safe_intel_atom(_), do: :hotspots

  defp fetch_intel(type, project, params) do
    case type do
      :hotspots ->
        # Native hotspots — top modules by symbol count + dependency count
        modules = CodebaseReader.list_modules(project)

        hotspots =
          modules
          |> Enum.map(fn m ->
            %{
              "path" => m.path,
              "symbols" => m.symbol_count,
              "exports" => m.exported_count,
              "deps" => m.dep_count
            }
          end)
          |> Enum.sort_by(&(-(&1["symbols"] + &1["deps"])))
          |> Enum.take(30)

        {:ok, hotspots}

      :symbols ->
        # Native symbols — read from CodebaseReader module detail
        file = Map.get(params, :file, "")

        case CodebaseReader.get_module(file, project) do
          nil ->
            {:error, "Module not found: #{file}"}

          detail ->
            symbols =
              detail.symbols
              |> Enum.map(fn s ->
                %{
                  "name" => s.name,
                  "kind" => s.kind,
                  "line" => Map.get(s, :line),
                  "exported" => s.exported
                }
              end)

            {:ok, symbols}
        end

      :references ->
        # Native references — grep through indexed modules for symbol usage
        symbol = Map.get(params, :symbol, "")

        if symbol == "" do
          {:error, "Enter a symbol name to search"}
        else
          modules = CodebaseReader.list_modules(project)

          refs =
            modules
            |> Enum.flat_map(fn m ->
              case CodebaseReader.get_module(m.path, project) do
                nil ->
                  []

                detail ->
                  detail.edges
                  |> Enum.filter(fn edge ->
                    Enum.any?(edge.names, &String.contains?(&1, symbol))
                  end)
                  |> Enum.map(fn edge ->
                    %{
                      "file" => m.path,
                      "context" => "imports #{Enum.join(edge.names, ", ")} from #{edge.target}"
                    }
                  end)
              end
            end)
            |> Enum.take(50)

          {:ok, refs}
        end

      _ ->
        {:error, "Unknown intelligence type"}
    end
  rescue
    e -> {:error, "Error: #{inspect(e)}"}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp kind_hud_badge("class"), do: "text-[#ffa44c] border-[#ffa44c]/30"
  defp kind_hud_badge("interface"), do: "text-[#00eefc] border-[#00eefc]/30"
  defp kind_hud_badge("function"), do: "text-[#00FF41] border-[#00FF41]/30"
  defp kind_hud_badge("method"), do: "text-[#00FF41] border-[#00FF41]/30"
  defp kind_hud_badge("variable"), do: "text-[#ff725e] border-[#ff725e]/30"
  defp kind_hud_badge("type"), do: "text-[#00eefc] border-[#00eefc]/30"
  defp kind_hud_badge(_), do: "text-[#e0e0e0]/30 border-[#e0e0e0]/10"
end
