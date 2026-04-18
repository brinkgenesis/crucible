defmodule CrucibleWeb.TokenFlowLive do
  @moduledoc """
  Token Factory Pipeline Visibility — shows how raw inputs flow through
  the system and become higher-value outputs.

  Pipeline stages:
    Access → Memory → Expert → Context → Identity → Knowledge → Asset

  Displays:
  - Per-tier note counts and avg scores
  - Transformation ratio (% of notes above "memory" tier)
  - Flywheel velocities and momentum
  - Agent identity trust scores (KYA)
  - Attention budget utilization
  """
  use CrucibleWeb, :live_view

  alias CrucibleWeb.Live.RefreshTimer

  alias Crucible.{TokenValue, Flywheels, AgentIdentity, AttentionBudget}

  @refresh_interval 15_000

  @impl true
  def mount(_params, _session, socket) do
    timer = if connected?(socket), do: RefreshTimer.start(@refresh_interval)

    {:ok,
     assign(socket,
       page_title: "Token Flow",
       refresh_timer: timer,
       current_path: "/token-flow",
       loading: !connected?(socket)
     )
     |> load_data()}
  end

  @impl true
  def terminate(_reason, socket) do
    RefreshTimer.cancel(socket.assigns[:refresh_timer])
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, load_data(socket)}
  end

  defp load_data(socket) do
    infra_home = File.cwd!()

    # Scan vault notes for token value scoring
    notes = scan_vault_notes(infra_home)
    pipeline = TokenValue.pipeline_metrics(notes)

    # Flywheel state
    flywheels = safe_call(fn -> Flywheels.compute(infra_home) end, nil)

    flywheel_recs =
      if flywheels, do: Flywheels.recommendations(flywheels), else: []

    # Agent identities (KYA)
    agents = safe_call(fn -> AgentIdentity.list_agents(infra_home: infra_home) end, [])

    # Attention budget summary
    attention = safe_call(fn -> AttentionBudget.summary() end, %{agents: [], tasks: []})

    assign(socket,
      pipeline: pipeline,
      flywheels: flywheels,
      flywheel_recs: flywheel_recs,
      agents: agents,
      attention: attention,
      loading: false
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <.hud_header icon="token" label="TOKEN_FLOW" />

        <!-- Loading skeleton -->
        <div :if={@loading} class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div :for={_ <- 1..4} class="bg-surface-container-low hud-border animate-pulse">
            <div class="p-5"><div class="h-24 bg-surface-container rounded" /></div>
          </div>
        </div>

        <!-- Pipeline overview -->
        <div :if={!@loading}>
          <.hud_card accent="primary">
            <div class="flex items-center justify-between mb-4">
              <div class="flex items-center gap-2">
                <span class="material-symbols-outlined text-[#ffa44c] text-sm">filter_alt</span>
                <span class="font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60">Transformation Pipeline</span>
              </div>
              <div class="flex items-center gap-2">
                <span class="font-mono text-[10px] text-[#e0e0e0]/30">RATIO</span>
                <span class={[
                  "font-mono font-bold text-sm",
                  ratio_hud_color(@pipeline.transformation_ratio)
                ]}>
                  {pct(@pipeline.transformation_ratio)}
                </span>
              </div>
            </div>

            <div class="space-y-2">
              <div
                :for={
                  {tier, i} <-
                    Enum.with_index([
                      :access,
                      :memory,
                      :expert,
                      :context,
                      :identity,
                      :knowledge,
                      :asset
                    ])
                }
                class="flex items-center gap-3"
              >
                <span class={[
                  "w-20 font-mono text-[11px] text-right uppercase",
                  tier_hud_text_color(tier)
                ]}>
                  {tier}
                </span>
                <div class="flex items-center gap-0.5">
                  <span
                    :for={_ <- 1..(i + 1)}
                    class={["inline-block w-1 h-1 rounded-full", tier_hud_dot_color(tier)]}
                  />
                </div>
                <div class="flex-1 bg-surface-container rounded-full h-2.5 overflow-hidden">
                  <div
                    class={["h-full rounded-full transition-all", tier_hud_bar_color(tier)]}
                    style={"width: #{tier_bar_width(@pipeline.by_tier, tier)}%"}
                  />
                </div>
                <span class="font-mono text-[11px] w-8 text-right text-[#e0e0e0]/40">
                  {tier_count(@pipeline.by_tier, tier)}
                </span>
              </div>
            </div>

            <div class="mt-3 pt-3 border-t border-[#ffa44c]/10 flex items-center gap-4">
              <span class="font-mono text-[10px] text-[#e0e0e0]/30">TOTAL <span class="text-[#ffa44c]/60">{@pipeline.total_notes}</span></span>
              <span class="font-mono text-[10px] text-[#e0e0e0]/30">AVG VALUE <span class="text-[#00eefc]/60">{@pipeline.avg_value}</span></span>
            </div>
          </.hud_card>
        </div>

        <!-- Flywheels -->
        <div :if={!@loading && @flywheels}>
          <.hud_card>
            <div class="flex items-center gap-2 mb-4">
              <span class="material-symbols-outlined text-[#00eefc] text-sm">sync</span>
              <span class="font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60">Trust Flywheels</span>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
              <.flywheel_card
                name="Value"
                subtitle="outputs → satisfaction → more runs"
                data={@flywheels.value}
              />
              <.flywheel_card
                name="Expertise"
                subtitle="lessons → hints → better outputs"
                data={@flywheels.expertise}
              />
              <.flywheel_card
                name="Personalization"
                subtitle="preferences → adaptation → trust"
                data={@flywheels.personalization}
              />
            </div>

            <div class="mt-3 pt-3 border-t border-[#ffa44c]/10 flex items-center gap-3">
              <span class="font-mono text-[10px] text-[#e0e0e0]/30">OVERALL HEALTH</span>
              <span class={["font-mono font-bold text-sm", health_hud_color(@flywheels.overall_health)]}>
                {pct(@flywheels.overall_health)}
              </span>
              <span class="px-1.5 py-0.5 font-mono text-[8px] uppercase border border-[#e0e0e0]/10 text-[#e0e0e0]/30 rounded">
                weakest: {@flywheels.weakest_flywheel}
              </span>
            </div>

            <div :if={@flywheel_recs != []} class="mt-2 space-y-0.5">
              <div :for={rec <- @flywheel_recs} class="flex items-start gap-2">
                <span class="text-[#ffa44c]/30 font-mono text-[10px] mt-0.5">▸</span>
                <span class="font-mono text-[11px] text-[#e0e0e0]/40">{rec}</span>
              </div>
            </div>
          </.hud_card>
        </div>

        <!-- Agent Identity (KYA) -->
        <div :if={!@loading && @agents != []}>
          <.hud_card>
            <div class="flex items-center gap-2 mb-4">
              <span class="material-symbols-outlined text-[#ff725e] text-sm">fingerprint</span>
              <span class="font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60">Agent Identity (KYA)</span>
            </div>
            <div class="overflow-x-auto">
              <table class="w-full">
                <thead>
                  <tr class="border-b border-[#ffa44c]/10">
                    <th class="text-left font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-2 px-3">Agent</th>
                    <th class="text-left font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-2 px-3">Trust</th>
                    <th class="text-right font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-2 px-3">Tasks</th>
                    <th class="text-right font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-2 px-3">Efficiency</th>
                    <th class="text-right font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 py-2 px-3">7d</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={agent <- Enum.take(@agents, 10)} class="border-b border-[#ffa44c]/5 hover:bg-[#ffa44c]/5">
                    <td class="font-mono text-[11px] text-[#00eefc] py-2 px-3">{agent.name}</td>
                    <td class="py-2 px-3">
                      <div class="flex items-center gap-1.5">
                        <div class="w-12 bg-surface-container rounded-full h-1.5">
                          <div
                            class={["h-full rounded-full", trust_hud_color(agent.trust_score)]}
                            style={"width: #{(agent.trust_score || 0.5) * 100}%"}
                          />
                        </div>
                        <span class="font-mono text-[10px] text-[#e0e0e0]/50">
                          {Float.round((agent.trust_score || 0.5) * 1.0, 2)}
                        </span>
                      </div>
                    </td>
                    <td class="text-right font-mono text-[11px] text-[#e0e0e0]/50 py-2 px-3">
                      {get_in(agent, [:identity, :track_record, :total_tasks]) ||
                        get_in(agent, [:performance, :events_7d]) || 0}
                    </td>
                    <td class="text-right font-mono text-[11px] text-[#e0e0e0]/50 py-2 px-3">
                      {get_in(agent, [:performance, :efficiency]) || "—"}
                    </td>
                    <td class="text-right font-mono text-[11px] text-[#e0e0e0]/50 py-2 px-3">
                      {get_in(agent, [:performance, :events_7d]) || 0}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </.hud_card>
        </div>

        <!-- Attention Budget -->
        <div :if={!@loading}>
          <.hud_card>
            <div class="flex items-center gap-2 mb-4">
              <span class="material-symbols-outlined text-[#ffa44c] text-sm">visibility</span>
              <span class="font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60">Attention Budget</span>
            </div>
            <div
              :if={@attention.agents == [] && @attention.tasks == []}
              class="text-center py-6 text-[#e0e0e0]/30"
            >
              <span class="material-symbols-outlined text-3xl opacity-30 block mb-2">visibility</span>
              <p class="font-mono text-xs">NO ATTENTION TRACKING DATA</p>
              <p class="font-mono text-[10px] text-[#e0e0e0]/20 mt-1">Agents record token consumption as they work</p>
            </div>
            <div :if={@attention.agents != []} class="space-y-2">
              <div :for={a <- @attention.agents} class="flex items-center gap-3">
                <span class="font-mono text-[11px] text-[#00eefc]/60 w-32 truncate" title={a.agent_id}>{a.agent_id}</span>
                <div class="flex-1 bg-surface-container rounded-full h-2 overflow-hidden">
                  <div
                    class={[
                      "h-full rounded-full transition-all",
                      if(a.consumed >= a.cap, do: "bg-[#ff7351]", else: "bg-[#00eefc]")
                    ]}
                    style={"width: #{min(100, a.consumed / max(a.cap, 1) * 100)}%"}
                  />
                </div>
                <span class="font-mono text-[10px] text-[#e0e0e0]/40 w-24 text-right">
                  {fmt_tokens(a.consumed)}/{fmt_tokens(a.cap)}
                </span>
              </div>
            </div>
          </.hud_card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- Flywheel card component ---

  attr :name, :string, required: true
  attr :subtitle, :string, required: true
  attr :data, :map, required: true

  defp flywheel_card(assigns) do
    ~H"""
    <div class="p-3 bg-surface-container rounded border border-[#ffa44c]/10">
      <div class="flex items-center justify-between mb-1">
        <span class="font-mono text-[11px] font-bold text-[#e0e0e0]/80">{@name}</span>
        <span class={["px-1.5 py-0.5 font-mono text-[8px] uppercase border rounded", momentum_hud_badge(@data.momentum)]}>
          {@data.momentum}
        </span>
      </div>
      <p class="font-mono text-[10px] text-[#e0e0e0]/20 mb-2">{@subtitle}</p>
      <div class="flex items-center gap-2">
        <div class="flex-1 bg-surface-container-low rounded-full h-2 overflow-hidden">
          <div
            class={["h-full rounded-full transition-all", velocity_hud_color(@data.velocity)]}
            style={"width: #{@data.velocity * 100}%"}
          />
        </div>
        <span class="font-mono text-[10px] text-[#e0e0e0]/40 w-12 text-right">{pct(@data.velocity)}</span>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp scan_vault_notes(infra_home) do
    vault_path = Path.join(infra_home, "memory")
    dirs = ["lessons", "observations", "decisions", "handoffs", "preferences", "tensions", "mocs"]

    dirs
    |> Enum.flat_map(fn dir ->
      dir_path = Path.join(vault_path, dir)

      if File.dir?(dir_path) do
        dir_path
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(fn file ->
          path = Path.join(dir_path, file)
          content = File.read!(path) |> String.slice(0..2000)

          %{
            type: dir |> String.trim_trailing("s"),
            content: content,
            tags: extract_tags(content),
            priority: extract_priority(content),
            file: file
          }
        end)
      else
        []
      end
    end)
  rescue
    _ -> []
  end

  defp extract_tags(content) do
    case Regex.run(~r/tags:\s*\[([^\]]*)\]/, content) do
      [_, tags_str] ->
        tags_str
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.trim(&1, "\""))

      _ ->
        []
    end
  end

  defp extract_priority(content) do
    case Regex.run(~r/priority:\s*(\w+)/, content) do
      [_, priority] -> priority
      _ -> "background"
    end
  end

  defp pct(val) when is_float(val), do: "#{Float.round(val * 100, 1)}%"
  defp pct(val) when is_integer(val), do: "#{val}%"
  defp pct(_), do: "—"

  defp fmt_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp fmt_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp fmt_tokens(n), do: "#{n}"

  defp ratio_hud_color(r) when r >= 0.5, do: "text-[#00FF41]"
  defp ratio_hud_color(r) when r >= 0.25, do: "text-[#ffa44c]"
  defp ratio_hud_color(_), do: "text-[#ff7351]"

  defp health_hud_color(h) when h >= 0.6, do: "text-[#00FF41]"
  defp health_hud_color(h) when h >= 0.3, do: "text-[#ffa44c]"
  defp health_hud_color(_), do: "text-[#ff7351]"

  defp tier_hud_text_color(:asset), do: "text-[#00FF41] font-bold"
  defp tier_hud_text_color(:knowledge), do: "text-[#00FF41]/80"
  defp tier_hud_text_color(:identity), do: "text-[#00eefc]"
  defp tier_hud_text_color(:context), do: "text-[#00eefc]/80"
  defp tier_hud_text_color(:expert), do: "text-[#ffa44c]"
  defp tier_hud_text_color(:memory), do: "text-[#e0e0e0]/40"
  defp tier_hud_text_color(:access), do: "text-[#e0e0e0]/20"

  defp tier_hud_dot_color(:asset), do: "bg-[#00FF41] shadow-[0_0_4px_#00FF41]"
  defp tier_hud_dot_color(:knowledge), do: "bg-[#00FF41]/80"
  defp tier_hud_dot_color(:identity), do: "bg-[#00eefc]"
  defp tier_hud_dot_color(:context), do: "bg-[#00eefc]/80"
  defp tier_hud_dot_color(:expert), do: "bg-[#ffa44c]"
  defp tier_hud_dot_color(:memory), do: "bg-[#e0e0e0]/20"
  defp tier_hud_dot_color(:access), do: "bg-[#e0e0e0]/10"

  defp tier_hud_bar_color(:asset), do: "bg-[#00FF41]"
  defp tier_hud_bar_color(:knowledge), do: "bg-[#00FF41]/80"
  defp tier_hud_bar_color(:identity), do: "bg-[#00eefc]"
  defp tier_hud_bar_color(:context), do: "bg-[#00eefc]/80"
  defp tier_hud_bar_color(:expert), do: "bg-[#ffa44c]"
  defp tier_hud_bar_color(:memory), do: "bg-[#e0e0e0]/20"
  defp tier_hud_bar_color(:access), do: "bg-[#e0e0e0]/10"

  defp tier_bar_width(by_tier, tier) do
    tier_data = Map.get(by_tier, tier, %{count: 0})
    max_count = by_tier |> Map.values() |> Enum.map(& &1.count) |> Enum.max(fn -> 1 end)
    if max_count > 0, do: Float.round(tier_data.count / max_count * 100, 1), else: 0
  end

  defp tier_count(by_tier, tier) do
    Map.get(by_tier, tier, %{count: 0}).count
  end

  defp trust_hud_color(score) when score >= 0.7, do: "bg-[#00FF41]"
  defp trust_hud_color(score) when score >= 0.4, do: "bg-[#ffa44c]"
  defp trust_hud_color(_), do: "bg-[#ff7351]"

  defp momentum_hud_badge(:accelerating), do: "text-[#00FF41] border-[#00FF41]/30"
  defp momentum_hud_badge(:steady), do: "text-[#00eefc] border-[#00eefc]/30"
  defp momentum_hud_badge(:decelerating), do: "text-[#ffa44c] border-[#ffa44c]/30"
  defp momentum_hud_badge(:stalled), do: "text-[#ff7351] border-[#ff7351]/30"
  defp momentum_hud_badge(_), do: "text-[#e0e0e0]/30 border-[#e0e0e0]/10"

  defp velocity_hud_color(v) when v >= 0.6, do: "bg-[#00FF41]"
  defp velocity_hud_color(v) when v >= 0.3, do: "bg-[#ffa44c]"
  defp velocity_hud_color(_), do: "bg-[#ff7351]"
end
