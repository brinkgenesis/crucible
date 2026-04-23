defmodule CrucibleWeb.SettingsLive do
  @moduledoc """
  LiveView for the system settings and health monitoring dashboard.

  Displays real-time telemetry including GenServer process health, TS dashboard
  connectivity (via circuit breaker), feature flag toggles, sandbox pool status,
  budget limits, environment variable presence, Claude Code hooks, alert history,
  and system version info.

  ## Socket Assigns

    * `:config` — static configuration map (budget limits, vault path, auth status)
    * `:genserver_status` — list of `%{name, alive}` for each monitored GenServer
    * `:api_server_up` — boolean, API server reachability via `ExternalCircuitBreaker`
    * `:env_keys` — list of `%{name, set}` for required environment variables
    * `:hooks` — list of `%{name, trigger}` for Claude Code lifecycle hooks
    * `:feature_flags` — list of `%{name, enabled}` for runtime feature flags
    * `:sandbox_status` — map with `:mode`, `:pool_available`, `:pool_target`, `:active_sandboxes`, `:active_runs`
    * `:alert_history` — recent alert entries from `AlertManager`
    * `:bulkhead_tenants` — per-tenant bulkhead concurrency counts from ETS
    * `:refresh_timer` — `RefreshTimer` reference for periodic health polling

  ## PubSub / Refresh

  Uses `RefreshTimer` to poll health every 30 seconds via `:refresh` messages.
  No PubSub subscriptions — all data is pulled on each refresh tick.
  """

  use CrucibleWeb, :live_view

  alias CrucibleWeb.Live.RefreshTimer

  @refresh_interval 30_000

  @genservers [
    {Crucible.BudgetTracker, "BudgetTracker"},
    {Crucible.CostEventReader, "CostEventReader"},
    {Crucible.Orchestrator, "Orchestrator"},
    {Crucible.ResultStore, "ResultStore"},
    {Crucible.ResultWriter, "ResultWriter"},
    {Crucible.WorkflowStore, "WorkflowStore"},
    {Crucible.SelfImprovement, "SelfImprovement"}
  ]

  @env_keys ~w(
    ANTHROPIC_API_KEY GOOGLE_API_KEY OPENAI_API_KEY MINIMAX_API_KEY
    OBSIDIAN_VAULT_NAME DAILY_BUDGET_LIMIT_USD AGENT_BUDGET_LIMIT_USD TASK_BUDGET_LIMIT_USD
  )

  @doc """
  Initializes the settings page with static configuration and live health data.

  Starts a `RefreshTimer` (30s interval) for connected clients to poll health.
  Assigns `:config` (budget limits, vault path, auth) and runs `load_health/1`
  to populate all dynamic assigns (GenServer status, flags, alerts, etc.).
  """
  @impl true
  def mount(_params, _session, socket) do
    timer = if connected?(socket), do: RefreshTimer.start(@refresh_interval)

    {:ok,
     assign(socket,
       page_title: "Settings",
       refresh_timer: timer,
       current_path: "/settings",
       config: build_config()
     )
     |> load_health()}
  end

  @doc "Cancels the refresh timer on LiveView shutdown."
  @impl true
  def terminate(_reason, socket) do
    RefreshTimer.cancel(socket.assigns[:refresh_timer])
  end

  @doc """
  Handles the periodic `:refresh` tick from `RefreshTimer`.

  Reloads all health data (GenServer status, feature flags, sandbox pool,
  alerts, bulkhead tenants) and reschedules the next tick.
  """
  @impl true
  def handle_info(:refresh, socket) do
    socket = load_health(socket)
    timer = RefreshTimer.tick(socket.assigns[:refresh_timer], true)
    {:noreply, assign(socket, refresh_timer: timer)}
  end

  @doc """
  Handles user interactions: toggle_flag (feature flags), test_webhook (alert test).
  """
  @impl true
  def handle_event("toggle_flag", %{"flag" => flag_str}, socket) do
    flag = String.to_existing_atom(flag_str)

    if Crucible.FeatureFlags.enabled?(flag) do
      Crucible.FeatureFlags.disable(flag)
    else
      Crucible.FeatureFlags.enable(flag)
    end

    {:noreply, load_health(socket)}
  end

  @doc false
  def handle_event("test_webhook", _params, socket) do
    case safe_call(fn -> Crucible.AlertManager.test_webhook() end, {:error, :not_available}) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Test webhook sent successfully")}

      {:error, :no_webhook_url} ->
        {:noreply, put_flash(socket, :error, "No webhook URL configured (set ALERT_WEBHOOK_URL)")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Webhook test failed: #{inspect(reason)}")}
    end
  end

  # ---------------------------------------------------------------------------
  # Data
  # ---------------------------------------------------------------------------

  defp build_config do
    orchestrator = Application.get_env(:crucible, :orchestrator, [])

    %{
      api_key_set: Application.get_env(:crucible, :api_key) != nil,
      daily_budget: Keyword.get(orchestrator, :daily_budget_usd, 100.0),
      agent_budget: Keyword.get(orchestrator, :agent_budget_usd, 10.0),
      task_budget: Keyword.get(orchestrator, :task_budget_usd, 50.0),
      cors_origins: Application.get_env(:crucible, :cors_origins, "localhost"),
      vault_path:
        Application.get_env(:crucible, :vault_path) ||
          System.get_env("CRUCIBLE_VAULT_PATH") ||
          "memory"
    }
  end

  defp load_health(socket) do
    genserver_status =
      Enum.map(@genservers, fn {mod, label} ->
        alive = Process.whereis(mod) != nil
        %{name: label, alive: alive}
      end)

    # Check TS dashboard reachability via circuit breaker state (no HTTP call)
    api_server_up =
      case Crucible.ExternalCircuitBreaker.check(:api_server) do
        :ok -> true
        _ -> false
      end

    env_keys =
      Enum.map(@env_keys, fn key ->
        %{name: key, set: (Crucible.Secrets.get(key) || System.get_env(key)) != nil}
      end)

    hooks = load_hooks()

    feature_flags =
      safe_call(fn -> Crucible.FeatureFlags.all() end, [])
      |> Enum.map(fn {flag, enabled} -> %{name: flag, enabled: enabled} end)
      |> Enum.sort_by(& &1.name)

    sandbox_status =
      safe_call(fn -> Crucible.Sandbox.Manager.status() end, %{
        mode: :local,
        pool_available: 0,
        pool_target: 0,
        active_sandboxes: 0,
        active_runs: 0
      })

    alert_history =
      safe_call(fn -> Crucible.AlertManager.alert_history(Crucible.AlertManager, 10) end, [])

    bulkhead_tenants =
      safe_call(
        fn ->
          :ets.tab2list(:bulkhead_counts)
          |> Enum.map(fn {tenant, count} -> %{tenant: tenant, current: count, limit: 5} end)
          |> Enum.sort_by(& &1.tenant)
        end,
        []
      )

    assign(socket,
      genserver_status: genserver_status,
      api_server_up: api_server_up,
      env_keys: env_keys,
      hooks: hooks,
      feature_flags: feature_flags,
      sandbox_status: sandbox_status,
      alert_history: alert_history,
      bulkhead_tenants: bulkhead_tenants
    )
  end

  defp load_hooks do
    hooks_dir = Path.expand("~/.claude/hooks")

    if File.dir?(hooks_dir) do
      Path.wildcard(Path.join(hooks_dir, "*.sh"))
      |> Enum.map(fn path ->
        name = Path.basename(path, ".sh")
        # Try to infer trigger from filename convention
        trigger = infer_hook_trigger(name)
        %{name: name, trigger: trigger}
      end)
      |> Enum.sort_by(& &1.name)
    else
      []
    end
  rescue
    _ -> []
  end

  defp infer_hook_trigger(name) do
    cond do
      String.contains?(name, "quality-gate") -> "TaskCompleted"
      String.contains?(name, "cost-tracker") -> "PostToolUse"
      String.contains?(name, "vault-validate") -> "PostToolUse"
      String.contains?(name, "session-logger") -> "SessionStart/End"
      String.contains?(name, "session-rotator") -> "SessionStart"
      String.contains?(name, "memory-precompact") -> "PreCompact"
      String.contains?(name, "compact-reinject") -> "SessionStart"
      true -> "—"
    end
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <%!-- Page header --%>
        <div class="flex flex-col md:flex-row md:items-end justify-between gap-4 mb-2">
          <div>
            <h1 class="text-3xl font-headline font-bold text-[#ffa44c] tracking-tighter uppercase">
              SYSTEM_CONFIGURATION
            </h1>
            <p class="font-mono text-xs text-[#00eefc] opacity-70 mt-1 tracking-widest">
              REALTIME_TELEMETRY_STREAMING // HEALTH_MONITOR_ACTIVE
            </p>
          </div>
          <div class="flex gap-2">
            <.hud_stat label="GLOBAL_HEALTH" value={health_pct(assigns)} color="primary" />
            <.hud_stat
              label="GENSERVERS"
              value={"#{Enum.count(@genserver_status, & &1.alive)}/#{length(@genserver_status)}"}
              color="secondary"
            />
          </div>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-12 gap-6">
          <%!-- Service Health --%>
          <.hud_card accent="secondary" class="md:col-span-4">
            <.hud_header icon="vital_signs" label="Service Health [GenServers]" class="mb-4" />
            <div class="grid grid-cols-2 gap-4">
              <div class="flex items-center gap-3">
                <span class={[
                  "w-3 h-3",
                  if(@api_server_up,
                    do: "bg-[#00FF41] shadow-[0_0_8px_rgba(0,255,65,0.6)]",
                    else: "bg-[#ff7351] shadow-[0_0_8px_rgba(255,115,81,0.6)]"
                  )
                ]} />
                <div class="font-mono text-[10px]">
                  <div class="text-white">API_SERVER</div>
                  <div class="text-[#494847]">
                    {if @api_server_up, do: "CONNECTED", else: "OPTIONAL"}
                  </div>
                </div>
              </div>
              <div :for={gs <- @genserver_status} class="flex items-center gap-3">
                <span class={[
                  "w-3 h-3",
                  if(gs.alive,
                    do: "bg-[#00FF41] shadow-[0_0_8px_rgba(0,255,65,0.6)]",
                    else: "bg-[#494847]"
                  )
                ]} />
                <div class="font-mono text-[10px]">
                  <div class="text-white">{String.upcase(gs.name)}</div>
                  <div class={if(gs.alive, do: "text-[#00eefc]", else: "text-[#ff7351]")}>
                    {if gs.alive, do: "RUNNING", else: "STOPPED"}
                  </div>
                </div>
              </div>
            </div>
          </.hud_card>

          <%!-- Feature Flags --%>
          <.hud_card class="md:col-span-5">
            <.hud_header icon="toggle_on" label="Feature Overrides [Flags]" class="mb-4" />
            <div class="space-y-3">
              <div
                :for={flag <- @feature_flags}
                class="flex items-center justify-between p-3 bg-surface-container-low border border-[#494847]/20"
              >
                <div class="font-mono">
                  <div class="text-[11px] text-white">{flag.name}</div>
                </div>
                <button
                  phx-click="toggle_flag"
                  phx-value-flag={flag.name}
                  class={[
                    "w-12 h-6 border relative cursor-pointer transition-colors",
                    if(flag.enabled,
                      do: "bg-[#ffa44c]/20 border-[#ffa44c]/50",
                      else: "bg-surface-container-highest border-[#494847]"
                    )
                  ]}
                >
                  <div class={[
                    "absolute top-1 w-4 h-4 transition-all",
                    if(flag.enabled,
                      do: "left-1 bg-[#ffa44c] shadow-[0_0_10px_rgba(255,164,76,0.5)]",
                      else: "right-1 bg-[#494847]"
                    )
                  ]} />
                </button>
              </div>
            </div>
          </.hud_card>

          <%!-- Sandbox Pool --%>
          <.hud_card accent="primary" class="md:col-span-3">
            <.hud_header icon="memory" label="Sandbox Resource Pool" class="mb-4" />
            <div class="space-y-6">
              <div>
                <div class="flex justify-between font-mono text-[10px] mb-1">
                  <span class="text-white">MODE</span>
                  <span class="text-[#ffa44c]">{@sandbox_status.mode}</span>
                </div>
              </div>
              <div>
                <div class="flex justify-between font-mono text-[10px] mb-1">
                  <span class="text-white">POOL_AVAILABLE</span>
                  <span class="text-[#00eefc]">
                    {@sandbox_status.pool_available}/{@sandbox_status.pool_target}
                  </span>
                </div>
                <div class="h-1 w-full bg-surface-container-highest">
                  <div
                    class="h-full bg-[#00eefc]"
                    style={"width: #{if @sandbox_status.pool_target > 0, do: min(@sandbox_status.pool_available / @sandbox_status.pool_target * 100, 100), else: 0}%"}
                  />
                </div>
              </div>
              <div class="pt-2 text-center">
                <div class="text-2xl font-black font-mono text-white">
                  {@sandbox_status.active_sandboxes}
                  <span class="text-[10px] text-[#494847] font-normal">ACTIVE</span>
                </div>
                <div class="text-[9px] font-mono text-[#ffa44c] uppercase">Running Instances</div>
              </div>
            </div>
          </.hud_card>
        </div>

        <%!-- Budget Limits --%>
        <.hud_card>
          <.hud_header icon="payments" label="Budget Limits" class="mb-4" />
          <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
            <div class="p-3 bg-surface-container-high border-l-2 border-[#ffa44c]/50">
              <div class="text-[9px] font-mono text-[#ffa44c]/70">DAILY_LIMIT</div>
              <div class="text-xl font-bold font-mono text-white">${@config.daily_budget}</div>
            </div>
            <div class="p-3 bg-surface-container-high border-l-2 border-[#00eefc]/50">
              <div class="text-[9px] font-mono text-[#00eefc]/70">PER_AGENT</div>
              <div class="text-xl font-bold font-mono text-white">${@config.agent_budget}</div>
            </div>
            <div class="p-3 bg-surface-container-high border-l-2 border-[#ff725e]/50">
              <div class="text-[9px] font-mono text-[#ff725e]/70">PER_TASK</div>
              <div class="text-xl font-bold font-mono text-white">${@config.task_budget}</div>
            </div>
          </div>
        </.hud_card>

        <%!-- Recent Alerts --%>
        <.hud_card accent="tertiary">
          <div class="flex items-center justify-between mb-4">
            <.hud_header icon="warning" label="Recent Alerts" class="mb-0" />
            <.tactical_button variant="ghost" phx-click="test_webhook">TEST_WEBHOOK</.tactical_button>
          </div>
          <div :if={@alert_history == []} class="font-mono text-[10px] text-[#494847] py-2">
            NO_ALERTS_FIRED_RECENTLY
          </div>
          <div :if={@alert_history != []} class="space-y-1">
            <div
              :for={alert <- @alert_history}
              class={[
                "flex items-center justify-between p-3 font-mono text-[11px]",
                if(alert.severity == :critical,
                  do: "bg-[#ff7351]/5",
                  else: "bg-surface-container-high"
                )
              ]}
            >
              <div class="flex items-center gap-2">
                <span class={[
                  "px-1.5 py-0.5 text-[8px] font-bold",
                  cond do
                    alert.severity == :critical -> "bg-[#ff7351] text-black"
                    alert.severity == :warning -> "bg-[#ffa44c] text-black"
                    true -> "bg-[#00eefc]/10 text-[#00eefc] border border-[#00eefc]/30"
                  end
                ]}>
                  {alert.severity}
                </span>
                <span class="text-white">{alert.rule}</span>
              </div>
              <span class="text-[#494847] truncate max-w-[300px]">
                {alert.message |> String.slice(0..60)}
              </span>
            </div>
          </div>
        </.hud_card>

        <%!-- Environment Variables --%>
        <.hud_card>
          <.hud_header icon="key" label="Environment Variables" class="mb-4" />
          <div class="grid grid-cols-2 md:grid-cols-4 gap-2">
            <div
              :for={env <- @env_keys}
              class="flex items-center gap-2 p-2 bg-surface-container-high"
            >
              <span class={[
                "w-2 h-2",
                if(env.set,
                  do: "bg-[#00FF41] shadow-[0_0_8px_rgba(0,255,65,0.6)]",
                  else: "bg-[#494847]"
                )
              ]} />
              <span class="font-mono text-[10px] truncate text-white">{env.name}</span>
            </div>
          </div>
        </.hud_card>

        <%!-- Hooks --%>
        <.hud_card :if={@hooks != []}>
          <.hud_header icon="webhook" label="Hooks" class="mb-4" />
          <div class="space-y-1">
            <div
              :for={hook <- @hooks}
              class="flex items-center justify-between p-3 bg-surface-container-high"
            >
              <span class="font-mono text-[11px] text-white">{hook.name}</span>
              <span class="px-1.5 py-0.5 bg-[#494847]/10 border border-[#494847]/30 text-[8px] font-mono text-[#494847]">
                {hook.trigger}
              </span>
            </div>
          </div>
        </.hud_card>

        <%!-- System Info --%>
        <.hud_card>
          <.hud_header icon="info" label="System Info" class="mb-4" />
          <div class="space-y-2">
            <div
              :for={
                {label, val} <- [
                  {"ELIXIR", System.version()},
                  {"OTP", :erlang.system_info(:otp_release) |> to_string()},
                  {"PHOENIX", Application.spec(:phoenix, :vsn) |> to_string()},
                  {"VAULT_PATH", @config.vault_path},
                  {"AUTH", if(@config.api_key_set, do: "ENABLED", else: "DISABLED")}
                ]
              }
              class="flex items-center justify-between font-mono text-[11px]"
            >
              <span class="text-[#ffa44c]/60 uppercase">{label}</span>
              <span class="text-white">{val}</span>
            </div>
          </div>
        </.hud_card>
      </div>
    </Layouts.app>
    """
  end

  defp health_pct(assigns) do
    alive = Enum.count(assigns.genserver_status, & &1.alive)
    total = length(assigns.genserver_status)
    if total > 0, do: "#{round(alive / total * 100)}%", else: "—"
  end
end
