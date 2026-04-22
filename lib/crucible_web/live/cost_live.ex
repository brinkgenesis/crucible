defmodule CrucibleWeb.CostLive do
  @moduledoc """
  LiveView for the Cost & Token Analytics dashboard.

  Displays real-time token usage, cost tracking, and budget monitoring across
  all Claude Code sessions. Merges data from two sources:

  - **Native cost events** (`CostEventReader`) — session-level cost/tool data from
    `cost-events.jsonl` or Postgres, refreshed every #{div(15_000, 1000)}s.
  - **LLM transcript usage** (`LLMUsageReader`) — per-model token breakdowns parsed
    from Claude session transcripts, refreshed every #{div(30_000, 1000)}s.

  The dashboard supports client/workspace scope filtering via URL params,
  model family filtering, paginated session tables, daily spend/token charts,
  budget status from `BudgetTracker`, and token-efficiency metrics from `SavingsReader`.

  Subscribes to `"budget:updates"` PubSub topic for real-time budget change pushes.
  """

  use CrucibleWeb, :live_view

  alias Crucible.{
    BudgetTracker,
    CostEventReader,
    LLMUsageReader,
    SavingsReader,
    TraceReader
  }

  alias Crucible.Utils.Range, as: RangeUtils

  alias CrucibleWeb.Live.ScopeFilters

  @refresh_fast 15_000
  @refresh_slow 30_000
  @sessions_per_page 50

  @model_colors %{
    "opus" => "#ff725e",
    "sonnet" => "#00eefc",
    "haiku" => "#00FF41",
    "minimax" => "#ffa44c",
    "gemini" => "#fd9000"
  }

  @impl true
  @doc """
  Initializes the cost dashboard socket with default assigns and starts periodic
  refresh timers. On connected mount, subscribes to budget PubSub and triggers
  an initial LLM usage load.
  """
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    connected = connected?(socket)

    if connected do
      Process.send_after(self(), :refresh_fast, @refresh_fast)
      Process.send_after(self(), :refresh_slow, @refresh_slow)
      send(self(), :load_llm_usage)
      Phoenix.PubSub.subscribe(Crucible.PubSub, "budget:updates")
    end

    socket =
      assign(socket,
        page_title: "Cost & Tokens",
        current_path: "/cost",
        client_filter: ScopeFilters.all_scope(),
        workspace_filter: ScopeFilters.all_scope(),
        client_options: ScopeFilters.client_options([]),
        workspace_options: ScopeFilters.workspace_options([]),
        view_mode: "tokens",
        model_filter: "all",
        session_page: 1,
        sessions_per_page: @sessions_per_page,
        llm_usage: empty_llm_usage(),
        llm_usage_loaded: false,
        cost_sessions_all: [],
        cost_sessions: [],
        session_rows: [],
        show_tools_column: false,
        run_scope_index: nil,
        chart_data_tokens: [],
        chart_data_dollars: [],
        last_updated_at: DateTime.utc_now()
      )
      |> load_data()

    socket = if connected, do: load_llm_usage(socket), else: socket

    {:ok, socket}
  end

  @impl true
  @doc """
  Applies client and workspace scope filters from URL query params, then reloads
  all dashboard data for the new scope.
  """
  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_params(params, _uri, socket) do
    client_filter = ScopeFilters.normalize_param(params["client_id"])
    workspace_filter = ScopeFilters.normalize_param(params["workspace"])

    {:noreply,
     socket
     |> assign(
       client_filter: client_filter,
       workspace_filter: workspace_filter,
       current_path: cost_path(client_filter, workspace_filter)
     )
     |> load_data()}
  end

  @impl true
  @doc """
  Handles periodic and PubSub messages.

  - `:refresh_fast` — reloads native cost data and savings every 15s.
  - `:refresh_slow` — reloads LLM transcript usage every 30s.
  - `:load_llm_usage` — one-shot initial LLM usage load on connected mount.
  - `{:budget_update, _}` — reloads native data when budget PubSub fires.
  """
  @spec handle_info(atom() | tuple(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info(:refresh_fast, socket) do
    Process.send_after(self(), :refresh_fast, @refresh_fast)

    {:noreply,
     load_native_data(socket) |> load_savings() |> assign(last_updated_at: DateTime.utc_now())}
  end

  def handle_info(:refresh_slow, socket) do
    Process.send_after(self(), :refresh_slow, @refresh_slow)
    {:noreply, load_llm_usage(socket)}
  end

  def handle_info(:load_llm_usage, socket), do: {:noreply, load_llm_usage(socket)}

  def handle_info({:budget_update, _}, socket),
    do: {:noreply, load_native_data(socket) |> assign(last_updated_at: DateTime.utc_now())}

  @impl true
  @doc """
  Handles UI interaction events from the dashboard.

  - `"toggle_view"` — switches between token and dollar chart views.
  - `"filter_model"` — filters the model breakdown table by family (opus/sonnet/haiku/etc.).
  - `"page_sessions"` — navigates the paginated session table.
  - `"set_scope_filters"` — applies client/workspace scope filters via URL patch.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("toggle_view", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, view_mode: mode)}
  end

  def handle_event("filter_model", %{"family" => family}, socket) do
    {:noreply, assign(socket, model_filter: family, session_page: 1)}
  end

  def handle_event("page_sessions", %{"page" => page}, socket) do
    {:noreply, assign(socket, session_page: max(1, String.to_integer(page)))}
  end

  def handle_event("set_scope_filters", params, socket) do
    client_filter = ScopeFilters.normalize_param(params["client_id"])
    workspace_filter = ScopeFilters.normalize_param(params["workspace"])
    {:noreply, push_patch(socket, to: cost_path(client_filter, workspace_filter))}
  end

  # ---------------------------------------------------------------------------
  # Data loading
  # ---------------------------------------------------------------------------

  defp load_data(socket) do
    socket |> load_native_data() |> load_savings()
  end

  defp load_native_data(socket) do
    client_id =
      ScopeFilters.query_value(socket.assigns[:client_filter] || ScopeFilters.all_scope())

    workspace =
      ScopeFilters.query_value(socket.assigns[:workspace_filter] || ScopeFilters.all_scope())

    cost_stats =
      safe_call(fn -> CostEventReader.stats(client_id: client_id, workspace: workspace) end, %{
        total_sessions: 0,
        total_tool_calls: 0,
        total_cost: 0.0
      })

    budget =
      safe_call(fn -> BudgetTracker.status() end, %{
        daily_spent: 0.0,
        daily_limit: 100.0,
        daily_remaining: 100.0,
        is_over_budget: false
      })

    daily_history = safe_call(fn -> BudgetTracker.daily_history(14) end, [])

    sessions =
      safe_call(
        fn ->
          CostEventReader.all_sessions(limit: 500, client_id: client_id, workspace: workspace)
        end,
        []
      )

    cost_source =
      safe_call(
        fn ->
          CostEventReader.source_status(limit: 500, client_id: client_id, workspace: workspace)
        end,
        %{
          source: :unknown,
          confidence: "low"
        }
      )

    assign(socket,
      cost_stats: cost_stats,
      budget: budget,
      daily_history: daily_history,
      cost_sessions_all: sessions,
      cost_source: cost_source
    )
    |> refresh_session_rows()
  end

  defp load_llm_usage(socket) do
    llm_usage =
      safe_call(
        fn -> LLMUsageReader.build_summary(session_limit: 200, min_file_size: 0) end,
        empty_llm_usage()
      )

    socket
    |> assign(llm_usage: llm_usage, llm_usage_loaded: true)
    |> refresh_session_rows()
  end

  defp load_savings(socket) do
    savings =
      safe_call(fn -> SavingsReader.build_global_savings() end, %{
        "totalEvents" => 0,
        "totalCompactTokens" => 0,
        "totalNaiveTokens" => 0,
        "totalSavedTokens" => 0,
        "totalSavedRatio" => 0.0,
        "byProject" => %{},
        "recentEvents" => []
      })

    assign(socket, savings: savings)
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  @doc """
  Renders the cost analytics dashboard with summary stats, daily chart,
  model breakdown table, paginated session table, and token efficiency panel.
  """
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
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
                TOKEN ANALYTICS / COST MONITORING
              </span>
            </div>
            <h1 class="text-3xl md:text-4xl font-headline font-bold text-white tracking-tighter uppercase">
              TOKEN_ANALYTICS<span class="text-[#ffa44c]">.SYS</span>
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

        <%!-- Summary stat cards --%>
        <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-5 gap-4">
          <.hud_stat
            label="TOTAL_TOKENS"
            value={format_tokens(summary_total_tokens(@session_rows))}
            color="primary"
            sub={"ACROSS #{length(@session_rows)} SESSIONS"}
          />
          <.hud_stat
            label="INPUT_TOKENS"
            value={format_tokens(summary_input_tokens(@session_rows))}
            color="secondary"
            sub="PROMPT_TOKENS"
          />
          <.hud_stat
            label="OUTPUT_TOKENS"
            value={format_tokens(summary_output_tokens(@session_rows))}
            color="tertiary"
            sub="COMPLETION_TOKENS"
          />
          <div class="bg-surface-container-low p-5 hud-border relative overflow-hidden">
            <div class="text-xs font-label tracking-widest mb-2 uppercase text-[#ffa44c]/60">
              CACHE_HIT_RATE
            </div>
            <div class="text-3xl font-headline font-bold tracking-tighter text-[#ffa44c]">
              {cache_hit_rate_rows(@session_rows)}
            </div>
            <div class="mt-2 text-[10px] font-label text-[#ffa44c]/60">TOKEN_CACHE_EFFICIENCY</div>
          </div>
          <div class="bg-surface-container-low p-5 hud-border relative overflow-hidden">
            <div class="text-xs font-label tracking-widest mb-2 uppercase text-[#00eefc]/60">
              CONTEXT_SAVED
            </div>
            <div class="text-3xl font-headline font-bold tracking-tighter text-[#00eefc]">
              {context_saved_pct(@savings)}
            </div>
            <div class="mt-2 text-[10px] font-label text-[#00eefc]/60">
              {String.upcase(context_saved_subtitle(@savings))}
            </div>
          </div>
        </div>

        <%!-- View toggle + daily chart --%>
        <.hud_card accent="primary">
          <div class="flex items-center justify-between mb-4">
            <h3 class="font-headline font-bold text-[#ffa44c] tracking-widest flex items-center gap-2 text-sm uppercase">
              <span class="material-symbols-outlined text-base">trending_up</span>
              DAILY_{if @view_mode == "dollars", do: "SPEND", else: "TOKEN_USAGE"}
            </h3>
            <div class="flex gap-1">
              <button
                phx-click="toggle_view"
                phx-value-mode="tokens"
                class={[
                  "px-3 py-1 font-mono text-[10px] tracking-widest transition-all",
                  if(@view_mode == "tokens",
                    do: "bg-[#ffa44c] text-black font-bold",
                    else: "border border-[#494847]/30 text-neutral-500 hover:text-[#00eefc]"
                  )
                ]}
              >
                TOKENS
              </button>
              <button
                phx-click="toggle_view"
                phx-value-mode="dollars"
                class={[
                  "px-3 py-1 font-mono text-[10px] tracking-widest transition-all",
                  if(@view_mode == "dollars",
                    do: "bg-[#ffa44c] text-black font-bold",
                    else: "border border-[#494847]/30 text-neutral-500 hover:text-[#00eefc]"
                  )
                ]}
              >
                $_SPEND
              </button>
            </div>
          </div>
          <.area_chart
            :if={@daily_history != []}
            data={if @view_mode == "dollars", do: @chart_data_dollars, else: @chart_data_tokens}
            id="daily-cost-chart"
            width={800}
            height={200}
            color={chart_color(@view_mode)}
            grid_color={chart_grid_color()}
            label_color={chart_label_color()}
          />
          <div :if={@daily_history == []} class="text-center py-8">
            <span class="material-symbols-outlined text-4xl text-[#494847]/30">timeline</span>
            <p class="text-[10px] font-mono text-neutral-500 mt-2">NO_DAILY_HISTORY_AVAILABLE</p>
          </div>
        </.hud_card>

        <%!-- Model breakdown --%>
        <.hud_card>
          <.hud_header icon="model_training" label="Model Breakdown" class="mb-4" />
          <div class="flex gap-1 flex-wrap mb-4">
            <button
              :for={family <- ["all", "opus", "sonnet", "haiku", "minimax", "gemini"]}
              phx-click="filter_model"
              phx-value-family={family}
              class={[
                "px-3 py-1 font-mono text-[10px] tracking-widest transition-all",
                if(@model_filter == family,
                  do: "bg-[#ffa44c] text-black font-bold",
                  else:
                    "border border-[#494847]/30 text-neutral-500 hover:border-[#00eefc] hover:text-[#00eefc]"
                )
              ]}
            >
              {String.upcase(family)}
            </button>
          </div>
          <div :if={model_rows(@session_rows, @model_filter) == []} class="text-center py-6">
            <span class="material-symbols-outlined text-4xl text-[#494847]/30">token</span>
            <p class="text-[10px] font-mono text-neutral-500 mt-2">NO_MODEL_DATA_AVAILABLE</p>
          </div>
          <div :if={model_rows(@session_rows, @model_filter) != []} class="overflow-x-auto">
            <table class="w-full text-left font-mono text-[11px]">
              <thead>
                <tr class="bg-black/40 text-[#777575] border-b border-[#494847]/10 uppercase tracking-widest">
                  <th class="px-4 py-3 font-normal">MODEL</th>
                  <th class="px-4 py-3 font-normal text-right">INPUT</th>
                  <th class="px-4 py-3 font-normal text-right">OUTPUT</th>
                  <th class="px-4 py-3 font-normal text-right">CACHE</th>
                  <th class="px-4 py-3 font-normal text-right">TOTAL</th>
                  <th class="px-4 py-3 font-normal text-right">TURNS</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-[#494847]/5">
                <tr
                  :for={row <- model_rows(@session_rows, @model_filter)}
                  class="hover:bg-[#00eefc]/5 transition-colors"
                >
                  <td class="px-4 py-3">
                    <div class="flex items-center gap-2">
                      <span class="w-2 h-2" style={"background:#{model_color(row.model)}"} />
                      <span class="text-white">{row.model}</span>
                    </div>
                  </td>
                  <td class="px-4 py-3 text-right text-white">{format_tokens(row.input)}</td>
                  <td class="px-4 py-3 text-right text-white">{format_tokens(row.output)}</td>
                  <td class="px-4 py-3 text-right text-[#00eefc]">{format_tokens(row.cache)}</td>
                  <td class="px-4 py-3 text-right text-white font-bold">
                    {format_tokens(row.total)}
                  </td>
                  <td class="px-4 py-3 text-right text-[#777575]">{row.turns}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.hud_card>

        <%!-- Session table --%>
        <div class="bg-surface-container-low border border-[#494847]/10 hud-border overflow-hidden">
          <div class="p-6 border-b border-[#494847]/10 flex flex-col md:flex-row justify-between items-start md:items-center bg-surface-container gap-3">
            <div>
              <h3 class="font-headline text-lg font-bold text-white uppercase flex items-center gap-2">
                <span class="w-1.5 h-6 bg-[#00eefc]" /> SESSION_ANALYTICS
              </h3>
              <div class="flex items-center gap-2 mt-1">
                <span class="text-[10px] font-mono text-[#777575]">SOURCE:</span>
                <span class={[
                  "px-1.5 py-0.5 text-[8px] font-mono font-bold",
                  case @cost_source.confidence do
                    "high" -> "bg-[#00FF41]/10 text-[#00FF41] border border-[#00FF41]/30"
                    "medium" -> "bg-[#ffa44c]/10 text-[#ffa44c] border border-[#ffa44c]/30"
                    _ -> "bg-[#ff7351]/10 text-[#ff7351] border border-[#ff7351]/30"
                  end
                ]}>
                  {source_label(@cost_source.source)}
                </span>
              </div>
            </div>
          </div>
          <div
            :if={!@llm_usage_loaded}
            class="px-6 py-2 text-[10px] font-mono text-[#00eefc] animate-pulse"
          >
            LOADING_TRANSCRIPT_TOKEN_MAPPING...
          </div>
          <div :if={@session_rows == []} class="text-center py-12">
            <span class="material-symbols-outlined text-4xl text-[#494847]/30">data_exploration</span>
            <p class="text-[10px] font-mono text-neutral-500 mt-2">NO_SESSION_DATA</p>
          </div>
          <div :if={@session_rows != []} class="overflow-x-auto">
            <table class="w-full text-left font-mono text-[11px]">
              <thead>
                <tr class="bg-black/40 text-[#777575] border-b border-[#494847]/10 uppercase tracking-widest">
                  <th class="px-4 py-4 font-normal">SESSION</th>
                  <th class="px-4 py-4 font-normal">PROJECT</th>
                  <th class="px-4 py-4 font-normal text-right">INPUT</th>
                  <th class="px-4 py-4 font-normal text-right">OUTPUT</th>
                  <th class="px-4 py-4 font-normal text-right">TOTAL</th>
                  <th class="px-4 py-4 font-normal text-right">TURNS</th>
                  <th :if={@show_tools_column} class="px-4 py-4 font-normal text-right">TOOLS</th>
                  <th class="px-4 py-4 font-normal text-right">COST</th>
                  <th class="px-4 py-4 font-normal">LAST_ACTIVE</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-[#494847]/5">
                <tr
                  :for={s <- paginated_sessions(@session_rows, @session_page)}
                  class="hover:bg-[#00eefc]/5 transition-colors"
                >
                  <td class="px-4 py-3 text-white font-bold">{s.short_id}</td>
                  <td class="px-4 py-3">
                    <span class="px-1.5 py-0.5 bg-[#494847]/10 border border-[#494847]/30 text-[9px] text-[#777575]">
                      {s.project}
                    </span>
                  </td>
                  <td class="px-4 py-3 text-right text-white">{format_tokens(s.input_tokens)}</td>
                  <td class="px-4 py-3 text-right text-white">{format_tokens(s.output_tokens)}</td>
                  <td class="px-4 py-3 text-right text-white font-bold">
                    {format_tokens(session_total_tokens(s))}
                  </td>
                  <td class="px-4 py-3 text-right text-[#777575]">{s.turns}</td>
                  <td :if={@show_tools_column} class="px-4 py-3 text-right text-[#777575]">
                    {s.tool_count}
                  </td>
                  <td class={[
                    "px-4 py-3 text-right",
                    if(Map.get(s, :execution_type) == "subscription",
                      do: "text-[#494847]",
                      else: "text-[#00eefc]"
                    )
                  ]}>
                    {if Map.get(s, :execution_type) == "subscription",
                      do: "—",
                      else: "$#{format_cost(s.total_cost_usd)}"}
                  </td>
                  <td class="px-4 py-3 text-[#777575]">{format_date(s.last_seen)}</td>
                </tr>
              </tbody>
            </table>
            <.cost_pagination
              page={@session_page}
              total={length(@session_rows)}
              per_page={@sessions_per_page}
            />
          </div>
        </div>

        <%!-- Token efficiency --%>
        <div :if={@savings} class="bg-surface-container-low p-6 hud-border">
          <.hud_header icon="speed" label="Token Efficiency" class="mb-4" />
          <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div class="p-3 bg-surface-container-high border-l-2 border-[#00FF41]/50">
              <div class="text-[9px] font-mono text-[#00FF41]/70 uppercase">TOKENS_SAVED</div>
              <div class="text-xl font-bold font-mono text-[#00FF41]">
                {format_tokens(@savings["totalSavedTokens"] || 0)}
              </div>
            </div>
            <div class="p-3 bg-surface-container-high border-l-2 border-[#ff725e]/50">
              <div class="text-[9px] font-mono text-[#ff725e]/70 uppercase">WITHOUT_MEMORY</div>
              <div class="text-xl font-bold font-mono text-[#ff725e]">
                {format_tokens(@savings["totalNaiveTokens"] || 0)}
              </div>
            </div>
            <div class="p-3 bg-surface-container-high border-l-2 border-[#00eefc]/50">
              <div class="text-[9px] font-mono text-[#00eefc]/70 uppercase">WITH_MEMORY</div>
              <div class="text-xl font-bold font-mono text-[#00eefc]">
                {format_tokens(@savings["totalCompactTokens"] || 0)}
              </div>
            </div>
            <div class="p-3 bg-surface-container-high border-l-2 border-[#ffa44c]/50">
              <div class="text-[9px] font-mono text-[#ffa44c]/70 uppercase">SAVINGS_EVENTS</div>
              <div class="text-xl font-bold font-mono text-white">
                {@savings["totalEvents"] || 0}
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Pagination component
  # ---------------------------------------------------------------------------

  attr :page, :integer, required: true
  attr :total, :integer, required: true
  attr :per_page, :integer, required: true

  defp cost_pagination(assigns) do
    total_pages = max(1, ceil(assigns.total / assigns.per_page))
    assigns = assign(assigns, total_pages: total_pages)

    ~H"""
    <div
      :if={@total_pages > 1}
      class="p-4 bg-black/40 border-t border-[#494847]/10 flex items-center justify-between"
    >
      <div class="text-[10px] font-mono text-[#777575]">
        SHOWING {(@page - 1) * @per_page + 1}-{min(@page * @per_page, @total)} OF {@total}
      </div>
      <div class="flex items-center gap-4">
        <button
          :if={@page > 1}
          phx-click="page_sessions"
          phx-value-page={@page - 1}
          class="text-[#777575] hover:text-white transition-colors"
        >
          <span class="material-symbols-outlined">chevron_left</span>
        </button>
        <div class="flex items-center gap-2 font-mono text-[10px]">
          <button
            :for={p <- page_range(@page, @total_pages)}
            phx-click="page_sessions"
            phx-value-page={p}
            class={[
              "px-2 py-0.5",
              if(p == @page,
                do: "text-white bg-[#ffa44c]/20 border border-[#ffa44c]/40",
                else: "text-[#777575] hover:text-white"
              )
            ]}
          >
            PAGE_{String.pad_leading(to_string(p), 2, "0")}
          </button>
        </div>
        <button
          :if={@page < @total_pages}
          phx-click="page_sessions"
          phx-value-page={@page + 1}
          class="text-[#777575] hover:text-white transition-colors"
        >
          <span class="material-symbols-outlined">chevron_right</span>
        </button>
      </div>
    </div>
    """
  end

  defp refresh_session_rows(socket) do
    llm_usage = socket.assigns[:llm_usage] || empty_llm_usage()
    cost_sessions_all = socket.assigns[:cost_sessions_all] || []
    client_filter = socket.assigns[:client_filter] || ScopeFilters.all_scope()
    workspace_filter = socket.assigns[:workspace_filter] || ScopeFilters.all_scope()

    # Cache run_scope — only rebuild if not already in assigns
    run_scope = socket.assigns[:run_scope_index] || build_run_scope_index()

    rows =
      session_rows(llm_usage, cost_sessions_all, run_scope)
      |> Enum.reject(&test_session_row?/1)

    filtered_rows = filter_rows_by_scope(rows, client_filter, workspace_filter)

    filtered_sessions =
      filter_sessions_by_scope(cost_sessions_all, run_scope, client_filter, workspace_filter)

    # Pre-compute chart data so render/1 doesn't recompute on every diff
    daily_history = socket.assigns[:daily_history] || []
    chart_data_tokens = daily_chart_data(daily_history, "tokens", filtered_rows)
    chart_data_dollars = daily_chart_data(daily_history, "dollars", filtered_rows)

    assign(socket,
      cost_sessions: filtered_sessions,
      session_rows: filtered_rows,
      run_scope_index: run_scope,
      chart_data_tokens: chart_data_tokens,
      chart_data_dollars: chart_data_dollars,
      client_options: rows |> Enum.map(&Map.get(&1, :client_id)) |> ScopeFilters.client_options(),
      workspace_options:
        rows |> Enum.map(&Map.get(&1, :workspace)) |> ScopeFilters.workspace_options(),
      show_tools_column: Enum.any?(filtered_rows, &(Map.get(&1, :tool_count, 0) > 0)),
      session_page: clamp_session_page(socket.assigns[:session_page] || 1, length(filtered_rows))
    )
  end

  defp empty_llm_usage do
    %{
      "totalTokens" => 0,
      "totalInputTokens" => 0,
      "totalOutputTokens" => 0,
      "totalCacheRead" => 0,
      "totalCacheCreation" => 0,
      "totalTurns" => 0,
      "sessionCount" => 0,
      "sessions" => [],
      "byModel" => %{},
      "byProject" => %{},
      "byDate" => %{},
      "byDateModel" => %{}
    }
  end

  # ---------------------------------------------------------------------------
  # Helpers — data extraction
  # ---------------------------------------------------------------------------

  defp summary_total_tokens(rows),
    do: Enum.reduce(rows, 0, &(&2 + session_total_tokens(&1)))

  defp summary_input_tokens(rows),
    do: Enum.reduce(rows, 0, &(&2 + (Map.get(&1, :input_tokens) || 0)))

  defp summary_output_tokens(rows),
    do: Enum.reduce(rows, 0, &(&2 + (Map.get(&1, :output_tokens) || 0)))

  defp cache_hit_rate_rows(rows) do
    total_input = summary_input_tokens(rows)
    total_cache_read = Enum.reduce(rows, 0, &(&2 + (Map.get(&1, :cache_read_tokens) || 0)))

    if total_input + total_cache_read > 0 do
      "#{Float.round(total_cache_read / (total_input + total_cache_read) * 100, 1)}%"
    else
      "\u2014"
    end
  end

  defp context_saved_pct(nil), do: "\u2014"

  defp context_saved_pct(%{"totalSavedRatio" => r}) when is_number(r),
    do: "#{Float.round(r * 100, 1)}%"

  defp context_saved_pct(_), do: "\u2014"

  defp context_saved_subtitle(nil), do: "no data"

  defp context_saved_subtitle(%{"totalSavedTokens" => t}) when is_number(t),
    do: "#{format_tokens(t)} tokens saved"

  defp context_saved_subtitle(_), do: "no data"

  # ---------------------------------------------------------------------------
  # Helpers — model breakdown
  # ---------------------------------------------------------------------------

  defp model_rows(rows, filter) when is_list(rows) do
    rows
    |> Enum.group_by(&(Map.get(&1, :model_id) || "unknown"))
    |> Enum.map(fn {model, model_rows} ->
      input = Enum.reduce(model_rows, 0, &(&2 + (Map.get(&1, :input_tokens) || 0)))
      output = Enum.reduce(model_rows, 0, &(&2 + (Map.get(&1, :output_tokens) || 0)))
      cache = Enum.reduce(model_rows, 0, &(&2 + (Map.get(&1, :cache_read_tokens) || 0)))
      total = Enum.reduce(model_rows, 0, &(&2 + session_total_tokens(&1)))
      turns = Enum.reduce(model_rows, 0, &(&2 + (Map.get(&1, :turns) || 0)))

      %{
        model: model,
        input: input,
        output: output,
        cache: cache,
        total: total,
        turns: turns,
        family: model_family(model)
      }
    end)
    |> filter_by_family(filter)
    |> Enum.sort_by(& &1.total, :desc)
  end

  defp model_rows(_, _), do: []

  defp filter_by_family(rows, "all"), do: rows
  defp filter_by_family(rows, family), do: Enum.filter(rows, &(&1.family == family))

  defp model_family(model) do
    m = String.downcase(model)

    cond do
      String.contains?(m, "opus") -> "opus"
      String.contains?(m, "sonnet") -> "sonnet"
      String.contains?(m, "haiku") -> "haiku"
      String.contains?(m, "minimax") or String.contains?(m, "m2") -> "minimax"
      String.contains?(m, "gemini") or String.contains?(m, "flash") -> "gemini"
      true -> "other"
    end
  end

  defp model_color(model), do: Map.get(@model_colors, model_family(model), "#94a3b8")

  defp chart_color("dollars"), do: "#ffa44c"
  defp chart_color(_), do: "#00eefc"

  defp chart_grid_color, do: "rgba(255, 164, 76, 0.08)"
  defp chart_label_color, do: "rgba(255, 164, 76, 0.5)"

  # ---------------------------------------------------------------------------
  # Helpers — daily chart
  # ---------------------------------------------------------------------------

  defp daily_chart_data(history, "dollars", rows) do
    cost_by_date =
      Enum.reduce(rows, %{}, fn row, acc ->
        date = (Map.get(row, :last_seen, "") || "") |> String.slice(0, 10)
        cost = Map.get(row, :total_cost_usd, 0.0) || 0.0
        Map.update(acc, date, cost, &(&1 + cost))
      end)

    Enum.map(history, fn day ->
      %{label: short_date(day.date), value: (Map.get(cost_by_date, day.date, 0.0) || 0.0) * 1.0}
    end)
  end

  defp daily_chart_data(history, "tokens", rows) do
    session_by_date = sessions_by_date(rows)

    Enum.map(history, fn day ->
      tokens = Map.get(session_by_date, day.date, 0)
      %{label: short_date(day.date), value: tokens * 1.0}
    end)
  end

  defp sessions_by_date(sessions) do
    Enum.reduce(sessions, %{}, fn s, acc ->
      date = (Map.get(s, :last_seen, "") || "") |> String.slice(0, 10)
      tokens = session_total_tokens(s)
      Map.update(acc, date, tokens, &(&1 + tokens))
    end)
  end

  defp session_total_tokens(%{total_tokens: total}) when is_number(total), do: total

  defp session_total_tokens(session) do
    Map.get(session, :total_input_tokens, Map.get(session, :input_tokens, 0)) +
      Map.get(session, :total_output_tokens, Map.get(session, :output_tokens, 0)) +
      Map.get(session, :total_cache_creation_tokens, Map.get(session, :cache_creation_tokens, 0))
  end

  # ---------------------------------------------------------------------------
  # Helpers — session table
  # ---------------------------------------------------------------------------

  defp session_rows(%{"sessions" => [_ | _] = llm_sessions}, cost_sessions, run_scope) do
    {cost_index, short_index} = build_cost_indexes(cost_sessions)

    llm_sessions
    |> Enum.map(fn session ->
      llm_session_id = session["sessionId"] || ""
      llm_short_id = String.slice(llm_session_id, 0, 8)

      cost_session =
        Map.get(cost_index, llm_session_id) ||
          Map.get(cost_index, llm_short_id) ||
          Map.get(short_index, llm_short_id) ||
          %{}

      run_scope_entry =
        run_scope
        |> Map.get(Map.get(cost_session, :run_id))
        |> Kernel.||(%{})

      workspace =
        Map.get(cost_session, :workspace_path) ||
          Map.get(run_scope_entry, :workspace) ||
          "unknown"

      client_id = Map.get(cost_session, :client_id) || Map.get(run_scope_entry, :client_id)

      input_tokens =
        preferred_number(
          session["inputTokens"],
          Map.get(cost_session, :total_input_tokens),
          0
        )

      output_tokens =
        preferred_number(
          session["outputTokens"],
          Map.get(cost_session, :total_output_tokens),
          0
        )

      cache_creation_tokens =
        preferred_number(
          session["cacheCreationTokens"],
          Map.get(cost_session, :total_cache_creation_tokens),
          0
        )

      cache_read_tokens =
        preferred_number(
          session["cacheReadTokens"],
          Map.get(cost_session, :total_cache_read_tokens),
          0
        )

      %{
        session_id: llm_session_id,
        short_id: llm_short_id,
        project: workspace,
        workspace: workspace,
        client_id: client_id,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        cache_creation_tokens: cache_creation_tokens,
        cache_read_tokens: cache_read_tokens,
        total_tokens:
          preferred_number(
            session["totalTokens"],
            input_tokens + output_tokens + cache_creation_tokens,
            0
          ),
        turns: session["turns"] || 0,
        last_seen: session["lastSeen"] || Map.get(cost_session, :last_seen),
        tool_count: Map.get(cost_session, :tool_count, 0),
        run_id: Map.get(cost_session, :run_id),
        total_cost_usd: Map.get(cost_session, :total_cost_usd, 0.0),
        execution_type: Map.get(cost_session, :execution_type) || session["executionType"],
        model_id: Map.get(cost_session, :model_id) || session["model"]
      }
    end)
    |> Enum.sort_by(&(&1.last_seen || ""), :desc)
  end

  defp session_rows(_, cost_sessions, run_scope) do
    cost_sessions
    |> Enum.map(fn session ->
      run_scope_entry = Map.get(run_scope, Map.get(session, :run_id), %{})

      workspace =
        Map.get(session, :workspace_path) ||
          Map.get(run_scope_entry, :workspace) ||
          "unknown"

      %{
        session_id: Map.get(session, :session_id),
        short_id:
          Map.get(session, :short_id) || String.slice(Map.get(session, :session_id, ""), 0, 8),
        project: workspace,
        workspace: workspace,
        client_id: Map.get(session, :client_id) || Map.get(run_scope_entry, :client_id),
        input_tokens: Map.get(session, :total_input_tokens, 0),
        output_tokens: Map.get(session, :total_output_tokens, 0),
        cache_creation_tokens: Map.get(session, :total_cache_creation_tokens, 0),
        cache_read_tokens: Map.get(session, :total_cache_read_tokens, 0),
        total_tokens: session_total_tokens(session),
        turns: 0,
        last_seen: Map.get(session, :last_seen),
        tool_count: Map.get(session, :tool_count, 0),
        run_id: Map.get(session, :run_id),
        total_cost_usd: Map.get(session, :total_cost_usd, 0.0),
        execution_type: Map.get(session, :execution_type),
        model_id: Map.get(session, :model_id)
      }
    end)
    |> Enum.sort_by(&(&1.last_seen || ""), :desc)
  end

  defp build_cost_indexes(cost_sessions) do
    Enum.reduce(cost_sessions, {%{}, %{}}, fn session, {id_index, short_index} ->
      id = Map.get(session, :session_id)
      short_id = Map.get(session, :short_id) || String.slice(id || "", 0, 8)
      run_id = Map.get(session, :run_id)
      run_short = if is_binary(run_id), do: String.slice(run_id, 0, 8), else: nil

      id_index =
        id_index
        |> maybe_put_index(id, session)
        |> maybe_put_index(short_id, session)
        |> maybe_put_index(run_id, session)
        |> maybe_put_index(run_short, session)

      short_index = maybe_put_index(short_index, short_id, session)
      {id_index, short_index}
    end)
  end

  defp maybe_put_index(index, nil, _session), do: index
  defp maybe_put_index(index, "", _session), do: index
  defp maybe_put_index(index, key, session), do: Map.put_new(index, key, session)

  defp preferred_number(primary, secondary, fallback) do
    p = number_or_nil(primary)
    s = number_or_nil(secondary)

    cond do
      is_number(p) and p > 0 -> p
      is_number(s) and s > 0 -> s
      is_number(p) -> p
      is_number(s) -> s
      true -> fallback
    end
  end

  defp number_or_nil(value) when is_integer(value) or is_float(value), do: value
  defp number_or_nil(_), do: nil

  defp test_session_row?(row) do
    fields =
      [
        Map.get(row, :session_id),
        Map.get(row, :run_id),
        Map.get(row, :project),
        Map.get(row, :model_id),
        Map.get(row, :last_seen)
      ]
      |> Enum.map(&to_string_or_empty/1)
      |> Enum.map(&String.downcase/1)

    Enum.any?(fields, &String.starts_with?(&1, "test")) or
      Enum.any?(fields, &String.contains?(&1, "test-run"))
  end

  defp to_string_or_empty(nil), do: ""
  defp to_string_or_empty(val), do: to_string(val)

  defp build_run_scope_index do
    TraceReader.list_runs()
    |> Enum.reduce(%{}, fn run, acc ->
      Map.put(acc, run.run_id, %{
        client_id: run.client_id,
        workspace: run.workspace_path
      })
    end)
  rescue
    _ -> %{}
  end

  defp filter_rows_by_scope(rows, client_filter, workspace_filter) do
    Enum.filter(rows, fn row ->
      ScopeFilters.matches_client?(Map.get(row, :client_id), client_filter) and
        ScopeFilters.matches_workspace?(Map.get(row, :workspace), workspace_filter)
    end)
  end

  defp filter_sessions_by_scope(cost_sessions, run_scope, client_filter, workspace_filter) do
    Enum.filter(cost_sessions, fn session ->
      run_scope_entry = Map.get(run_scope, Map.get(session, :run_id), %{})
      client_id = Map.get(session, :client_id) || Map.get(run_scope_entry, :client_id)
      workspace = Map.get(session, :workspace_path) || Map.get(run_scope_entry, :workspace)

      ScopeFilters.matches_client?(client_id, client_filter) and
        ScopeFilters.matches_workspace?(workspace, workspace_filter)
    end)
  end

  defp cost_path(client_filter, workspace_filter) do
    query =
      %{}
      |> ScopeFilters.apply_scope_query(client_filter, workspace_filter)

    "/cost" <> encode_query(query)
  end

  defp encode_query(query) when map_size(query) == 0, do: ""
  defp encode_query(query), do: "?" <> URI.encode_query(query)

  defp paginated_sessions(sessions, page) do
    chunks = RangeUtils.chunk_range(length(sessions), @sessions_per_page)

    case Enum.at(chunks, page - 1) do
      {offset, limit} -> Enum.slice(sessions, offset, limit)
      nil -> []
    end
  end

  defp clamp_session_page(page, total_rows) do
    max_page = max(1, ceil(total_rows / @sessions_per_page))
    RangeUtils.clamp(page, 1, max_page)
  end

  defp page_range(current, total_pages) do
    start = max(1, current - 2)
    stop = min(total_pages, current + 2)
    RangeUtils.range(start, stop)
  end

  # ---------------------------------------------------------------------------
  # Helpers — formatting
  # ---------------------------------------------------------------------------

  defp format_cost(val) when is_number(val), do: Float.round(val * 1.0, 2) |> to_string()
  defp format_cost(_), do: "0.00"

  defp format_date(nil), do: "\u2014"
  defp format_date(ts) when is_binary(ts), do: String.slice(ts, 0, 10)

  defp short_date(date) when is_binary(date) do
    case String.split(date, "-") do
      [_, m, d] -> "#{String.to_integer(m)}/#{String.to_integer(d)}"
      _ -> date
    end
  end

  defp source_label(:postgres), do: "Postgres"
  defp source_label(:jsonl), do: "JSONL"
  defp source_label(:empty), do: "Empty"
  defp source_label(_), do: "Unknown"
end
