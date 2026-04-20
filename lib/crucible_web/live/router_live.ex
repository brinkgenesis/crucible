defmodule CrucibleWeb.RouterLive do
  @moduledoc """
  LiveView dashboard for the model router.

  Displays the routing table of registered LLM models, provider health status,
  per-model cost information (input/output per 1k tokens), and circuit breaker
  states for each provider. The view auto-refreshes every 10 seconds when the
  client is connected via WebSocket.

  ## Socket Assigns

    * `:page_title` - `"Router"`, used by the layout for the browser tab title.
    * `:current_path` - `"/router"`, highlights the active nav item in the sidebar.
    * `:refresh_timer` - `RefreshTimer` reference for the periodic reload cycle.
    * `:loading` - boolean, `true` until the first data load completes (shows skeleton UI).
    * `:models` - list of maps with keys `"id"`, `"provider"`, `"contextWindow"`,
      `"inputCostPer1k"`, and `"outputCostPer1k"` from `ModelRegistry.list_models/0`.
    * `:providers` - map of `%{provider_name => true}` for active providers.
    * `:circuits` - map of `%{name => %{"state" => state, "failures" => count}}`
      from `ModelRegistry.circuit_states/0`.
    * `:router_reachable` - boolean indicating whether the router data source is available.
  """

  use CrucibleWeb, :live_view

  alias CrucibleWeb.Live.RefreshTimer

  alias Crucible.ModelRegistry

  @refresh_interval 10_000

  @doc """
  Mounts the router dashboard.

  Starts a periodic refresh timer when the socket is connected and loads the
  initial routing table, provider list, and circuit breaker data.
  """
  @impl true
  def mount(_params, _session, socket) do
    timer = if connected?(socket), do: RefreshTimer.start(@refresh_interval)

    {:ok,
     assign(socket,
       page_title: "Router",
       refresh_timer: timer,
       current_path: "/router",
       loading: !connected?(socket)
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
  Handles the periodic `:refresh` message from `RefreshTimer`.

  Reloads model, provider, and circuit breaker data, then schedules the next tick.
  """
  @impl true
  def handle_info(:refresh, socket) do
    socket = load_data(socket)
    timer = RefreshTimer.tick(socket.assigns[:refresh_timer], true)
    {:noreply, assign(socket, refresh_timer: timer)}
  end

  @doc """
  Handles the `"reset_circuit"` event triggered by the RESET button on an open
  or half-open circuit breaker card.

  Converts the provider name to an existing atom and calls
  `ExternalCircuitBreaker.reset/1`. Flashes a success or error message
  depending on whether the atom exists.
  """
  @impl true
  def handle_event("reset_circuit", %{"provider" => provider}, socket) do
    service = String.to_existing_atom(provider)
    Crucible.ExternalCircuitBreaker.reset(service)
    {:noreply, socket |> put_flash(:info, "Circuit breaker for #{provider} reset to closed") |> load_data()}
  rescue
    ArgumentError ->
      {:noreply, put_flash(socket, :error, "Unknown provider: #{provider}")}
  end

  defp load_data(socket) do
    # Native data — no TS dependency
    models =
      ModelRegistry.list_models()
      |> Enum.map(fn m ->
        %{
          "id" => m.id,
          "provider" => m.provider,
          "contextWindow" => m.context_window,
          "inputCostPer1k" => m.input_cost_per_1k,
          "outputCostPer1k" => m.output_cost_per_1k
        }
      end)

    providers =
      ModelRegistry.list_providers()
      |> Enum.into(%{}, fn p -> {p.name, true} end)

    circuits = ModelRegistry.circuit_states()

    assign(socket,
      models: models,
      providers: providers,
      circuits: circuits,
      router_reachable: true,
      loading: false
    )
  end

  @doc """
  Renders the router dashboard.

  Displays three sections: header stats (model count, provider count, online status),
  the routing table with per-model cost and context window info, and circuit breaker
  cards with state indicators and reset buttons.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <.hud_header icon="route" label="MODEL_ROUTER" />

        <!-- Header stats -->
        <div class="flex items-center gap-6">
          <.hud_stat label="MODELS" value={Integer.to_string(length(@models))} color="primary" />
          <.hud_stat label="PROVIDERS" value={Integer.to_string(map_size(@providers))} color="secondary" />
          <.hud_stat
            label="STATUS"
            value={if @router_reachable, do: "ONLINE", else: "OFFLINE"}
            color={if @router_reachable, do: "secondary", else: "tertiary"}
          />
        </div>

        <!-- Loading skeleton -->
        <div :if={@loading} class="bg-surface-container-low hud-border animate-pulse">
          <div class="p-5"><div class="h-32 bg-surface-container rounded" /></div>
        </div>

        <!-- Connection error banner -->
        <div :if={!@loading && !@router_reachable} class="flex items-center gap-3 px-4 py-3 border border-[#ffa44c]/30 bg-[#ffa44c]/5 rounded font-mono text-xs text-[#ffa44c]">
          <span class="material-symbols-outlined text-sm">warning</span>
          <div>
            <span class="font-bold">ROUTER UNREACHABLE</span>
            <span class="text-[#ffa44c]/60 ml-2">ModelRegistry returned no data</span>
          </div>
        </div>

        <!-- Routing Table -->
        <div :if={!@loading}>
          <.hud_card>
            <div class="flex items-center justify-between mb-4">
              <div class="font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60">Routing Table</div>
              <div :if={@router_reachable} class="flex items-center gap-1.5">
                <span class="w-1.5 h-1.5 bg-[#00FF41] rounded-full animate-pulse shadow-[0_0_6px_#00FF41]" />
                <span class="font-mono text-[10px] text-[#00FF41]/70">CONNECTED</span>
              </div>
            </div>
            <div :if={@models == []} class="text-center py-8 text-[#e0e0e0]/30">
              <span class="material-symbols-outlined text-3xl opacity-30 block mb-2">memory</span>
              <p class="font-mono text-xs">{if @router_reachable, do: "NO_MODELS_CONFIGURED", else: "UNABLE_TO_LOAD_ROUTING_TABLE"}</p>
            </div>
            <div :if={@models != [] and is_list(@models)} class="overflow-x-auto">
              <table class="w-full">
                <thead>
                  <tr class="border-b border-[#ffa44c]/10">
                    <th class="text-left font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-2 px-3">Model</th>
                    <th class="text-left font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-2 px-3">Provider</th>
                    <th class="text-right font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-2 px-3">Context</th>
                    <th class="text-right font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-2 px-3">Cost (in/out)</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={model <- @models} class="border-b border-[#ffa44c]/5 hover:bg-[#ffa44c]/5 transition-colors">
                    <td class="font-mono text-[11px] text-[#00eefc] py-2 px-3" title={Map.get(model, "id", "—")}>
                      {Map.get(model, "id", "—")}
                    </td>
                    <td class="py-2 px-3">
                      <span class="px-1.5 py-0.5 font-mono text-[8px] font-bold uppercase text-[#ffa44c]/60 border border-[#ffa44c]/20 rounded">
                        {Map.get(model, "provider", "—")}
                      </span>
                    </td>
                    <td class="font-mono text-[11px] text-[#e0e0e0]/60 text-right py-2 px-3">
                      {format_tokens(Map.get(model, "contextWindow"))}
                    </td>
                    <td class="font-mono text-[11px] text-[#e0e0e0]/60 text-right py-2 px-3">
                      <span class="text-[#00FF41]/70">${Map.get(model, "inputCostPer1k", "?")}</span>
                      <span class="text-[#e0e0e0]/20"> / </span>
                      <span class="text-[#ff725e]/70">${Map.get(model, "outputCostPer1k", "?")}</span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </.hud_card>
        </div>

        <!-- Circuit Breakers -->
        <div :if={!@loading}>
          <.hud_card>
            <div class="font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 mb-4">Circuit Breakers</div>
            <div :if={@circuits == [] or @circuits == %{}} class="text-center py-8 text-[#e0e0e0]/30">
              <span class="material-symbols-outlined text-3xl opacity-30 block mb-2">electric_bolt</span>
              <p class="font-mono text-xs">NO_CIRCUIT_DATA_AVAILABLE</p>
            </div>
            <div :if={is_map(@circuits) and @circuits != %{}} class="grid grid-cols-2 md:grid-cols-4 gap-3">
              <div :for={{name, info} <- @circuits} class="p-3 bg-surface-container rounded border border-[#ffa44c]/10">
                <div class="font-mono text-[11px] font-bold text-[#e0e0e0]/80 truncate" title={name}>{name}</div>
                <div class="flex items-center gap-1.5 mt-1.5">
                  <span class={[
                    "w-2 h-2 rounded-full",
                    circuit_hud_dot(Map.get(info, "state", "closed"))
                  ]} />
                  <span class={[
                    "font-mono text-[11px] uppercase",
                    circuit_hud_color(Map.get(info, "state", "closed"))
                  ]}>
                    {Map.get(info, "state", "closed")}
                  </span>
                </div>
                <div class="font-mono text-[10px] text-[#e0e0e0]/30 mt-0.5">
                  {Map.get(info, "failures", 0)} failures
                </div>
                <button
                  :if={Map.get(info, "state", "closed") != "closed"}
                  phx-click="reset_circuit"
                  phx-value-provider={name}
                  class="mt-2 px-2 py-0.5 font-mono text-[9px] tracking-widest uppercase text-[#ffa44c]/60 border border-[#ffa44c]/20 rounded hover:bg-[#ffa44c]/10 hover:text-[#ffa44c] transition-colors"
                >
                  RESET
                </button>
              </div>
            </div>
          </.hud_card>
        </div>
      </div>
    </Layouts.app>
    """
  end


  defp circuit_hud_color("closed"), do: "text-[#00FF41]"
  defp circuit_hud_color("open"), do: "text-[#ff7351]"
  defp circuit_hud_color("half_open"), do: "text-[#ffa44c]"
  defp circuit_hud_color(_), do: "text-[#e0e0e0]/40"

  defp circuit_hud_dot("closed"), do: "bg-[#00FF41] shadow-[0_0_6px_#00FF41]"
  defp circuit_hud_dot("open"), do: "bg-[#ff7351] shadow-[0_0_6px_#ff7351]"
  defp circuit_hud_dot("half_open"), do: "bg-[#ffa44c] shadow-[0_0_6px_#ffa44c]"
  defp circuit_hud_dot(_), do: "bg-[#e0e0e0]/30"
end
