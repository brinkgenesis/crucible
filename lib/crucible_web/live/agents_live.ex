defmodule CrucibleWeb.AgentsLive do
  use CrucibleWeb, :live_view

  # Agent YAML definitions live at the infra project root (one level above orchestrator/)
  defp agents_dir do
    Application.get_env(
      :crucible,
      :agents_dir,
      Path.expand("../.claude/agents")
    )
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Crucible.PubSub, "voice:events")
    end

    {:ok,
     assign(socket,
       page_title: "Agents",
       current_path: "/agents",
       agents: load_agents(),
       selected: nil,
       voice_sessions: []
     )}
  end

  @impl true
  def handle_info({:voice_session_update, sessions}, socket) do
    {:noreply, assign(socket, voice_sessions: sessions)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_agent", %{"name" => name}, socket) do
    selected = if socket.assigns.selected == name, do: nil, else: name
    {:noreply, assign(socket, selected: selected)}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <!-- Header -->
        <div class="flex flex-col md:flex-row md:items-end justify-between gap-6 mb-4">
          <div>
            <h1 class="font-headline text-4xl font-black text-[#ffa44c] uppercase tracking-tighter leading-none mb-2">
              AGENT_MESH
            </h1>
            <p class="font-label text-xs text-[#00eefc]/60 uppercase tracking-widest">Entity Definitions & Configuration Registry</p>
          </div>
          <div class="flex items-center gap-2">
            <span class="font-label text-[10px] text-[#00eefc] px-2 bg-[#00eefc]/10 border border-[#00eefc]/20">
              LIVE_COUNT: {length(@agents)}
            </span>
          </div>
        </div>

        <div :if={@agents == []} class="bg-surface-container-low p-12 hud-border text-center">
          <span class="material-symbols-outlined text-4xl text-[#ffa44c]/30 mb-3 block">hub</span>
          <p class="font-label text-[10px] text-[#adaaaa]/60 uppercase tracking-widest">NO_AGENT_DEFINITIONS_FOUND</p>
          <p class="font-label text-[9px] text-[#ffa44c]/40 mt-1">.claude/agents/</p>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-12 gap-6">
          <!-- Agent Grid (Left) -->
          <div :if={@agents != []} class={"#{if @selected, do: "lg:col-span-8", else: "lg:col-span-12"} space-y-4"}>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div
                :for={agent <- @agents}
                phx-click="select_agent"
                phx-value-name={agent.name}
                class={"bg-surface-container-low p-4 border-l-2 hover:bg-surface-container transition-colors cursor-pointer group #{if @selected == agent.name, do: "border-[#00eefc] bg-surface-container", else: "border-[#ffa44c]/30"}"}
              >
                <div class="flex justify-between items-start mb-3">
                  <div>
                    <div class={"font-label text-xs font-bold #{if @selected == agent.name, do: "text-[#00eefc]", else: "text-[#ffa44c]"}"}>{humanize_name(agent.name)}</div>
                    <div class="font-label text-[9px] text-[#ffa44c]/60 uppercase">{role_label(agent.name)}</div>
                  </div>
                  <span class={"px-2 py-0.5 font-label text-[8px] uppercase #{nerv_role_badge(agent.name)}"}>
                    {role_label(agent.name)}
                  </span>
                </div>
                <p :if={agent.description} class="text-[10px] text-[#adaaaa]/80 mb-3 line-clamp-2">
                  {agent.description}
                </p>
                <div class="flex flex-wrap gap-1.5">
                  <span :if={agent.model} class="text-[8px] font-label px-1.5 py-0.5 bg-[#ffa44c]/10 text-[#ffa44c] border border-[#ffa44c]/20 uppercase">
                    {agent.model}
                  </span>
                  <span
                    :for={cap <- Enum.take(agent.capabilities, 3)}
                    class="text-[8px] font-label px-1.5 py-0.5 bg-[#494847]/30 text-[#adaaaa] uppercase"
                  >
                    {cap}
                  </span>
                  <span :if={length(agent.capabilities) > 3} class="text-[8px] font-label px-1.5 py-0.5 text-[#adaaaa]/40">
                    +{length(agent.capabilities) - 3}
                  </span>
                </div>
              </div>
            </div>
          </div>

          <!-- Detail Panel (Right) -->
          <div :if={@selected} class="lg:col-span-4">
            <div class="bg-surface-container-low border border-[#494847]/10 h-full flex flex-col">
              <% agent = Enum.find(@agents, &(&1.name == @selected)) %>
              <div :if={agent}>
                <div class="p-6 border-b border-[#494847]/20 bg-gradient-to-br from-[#ffa44c]/5 to-transparent">
                  <div class="flex items-center justify-between mb-4">
                    <h3 class="font-headline text-xl font-bold text-[#ffa44c] uppercase tracking-widest">{humanize_name(agent.name)}</h3>
                    <button phx-click="select_agent" phx-value-name={agent.name} class="text-[#ffa44c]/40 hover:text-[#ffa44c]">
                      <span class="material-symbols-outlined text-sm">close</span>
                    </button>
                  </div>

                  <p :if={agent.description} class="text-xs text-[#adaaaa]/80 mb-4">{agent.description}</p>

                  <div class="space-y-4">
                    <!-- Model -->
                    <div>
                      <div class="flex items-center gap-2 mb-2">
                        <span class="w-1 h-3 bg-[#ffa44c]"></span>
                        <span class="font-label text-[9px] text-[#ffa44c] uppercase font-bold tracking-widest">MODEL</span>
                      </div>
                      <span class="text-[10px] font-label px-2 py-1 bg-[#ffa44c]/10 text-[#ffa44c] border border-[#ffa44c]/20">
                        {agent.model || "default"}
                      </span>
                    </div>

                    <!-- Capabilities -->
                    <div>
                      <div class="flex items-center gap-2 mb-2">
                        <span class="w-1 h-3 bg-[#00eefc]"></span>
                        <span class="font-label text-[9px] text-[#00eefc] uppercase font-bold tracking-widest">CAPABILITIES ({length(agent.capabilities)})</span>
                      </div>
                      <div class="flex flex-wrap gap-1">
                        <span :for={cap <- agent.capabilities} class="bg-surface-container p-2 border border-[#494847]/10 text-[10px] font-label text-[#adaaaa]/80">
                          {cap}
                        </span>
                        <span :if={agent.capabilities == []} class="text-[10px] font-label text-[#adaaaa]/40 italic">NONE_SPECIFIED</span>
                      </div>
                    </div>

                    <!-- Denied Tools -->
                    <div>
                      <div class="flex items-center gap-2 mb-2">
                        <span class="w-1 h-3 bg-[#ff725e]"></span>
                        <span class="font-label text-[9px] text-[#ff725e] uppercase font-bold tracking-widest">DENIED_TOOLS ({length(agent.denied_tools)})</span>
                      </div>
                      <div class="flex flex-wrap gap-1">
                        <span :for={tool <- agent.denied_tools} class="text-[10px] font-label px-1.5 py-0.5 bg-[#ff725e]/10 text-[#ff725e] border border-[#ff725e]/20">
                          {tool}
                        </span>
                        <span :if={agent.denied_tools == []} class="text-[10px] font-label text-[#adaaaa]/40">NONE</span>
                      </div>
                    </div>
                  </div>
                </div>

                <!-- System prompt -->
                <div :if={agent.system_prompt} class="p-4 bg-black/40 flex-1">
                  <div class="font-label text-[8px] text-[#00eefc]/40 uppercase mb-3 tracking-tighter">SYSTEM_PROMPT_PREVIEW</div>
                  <pre class="text-[10px] font-label text-[#adaaaa]/70 whitespace-pre-wrap break-words max-h-48 overflow-y-auto leading-relaxed">{String.slice(agent.system_prompt, 0, 2000)}</pre>
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- Voice Sessions -->
        <div class="bg-surface-container-low hud-border p-4">
          <div class="flex items-center gap-2 mb-3">
            <span class="w-1 h-3 bg-[#00eefc]"></span>
            <span class="font-label text-[9px] text-[#00eefc] uppercase font-bold tracking-widest">VOICE_SESSIONS</span>
            <span :if={@voice_sessions != []} class="ml-auto px-2 py-0.5 bg-[#00eefc]/10 border border-[#00eefc]/30 font-label text-[9px] text-[#00eefc]">
              🎤 {length(@voice_sessions)} active
            </span>
          </div>
          <div :if={@voice_sessions == []} class="font-label text-[10px] text-[#adaaaa]/40 uppercase">
            NO_ACTIVE_VOICE_SESSIONS
          </div>
          <div :if={@voice_sessions != []} class="space-y-2">
            <div
              :for={vs <- @voice_sessions}
              class="flex flex-col gap-1 border border-[#00eefc]/10 bg-black/20 p-2"
            >
              <div class="flex items-center gap-2">
                <span class="font-label text-[9px] text-[#00eefc]/60 uppercase">ID:</span>
                <span class="font-label text-[9px] text-[#adaaaa]">{String.slice(to_string(vs.session_id), 0, 16)}…</span>
                <span class={"ml-auto px-1.5 py-0.5 font-label text-[8px] uppercase #{voice_status_badge(vs.status)}"}>
                  {vs.status}
                </span>
              </div>
              <div :if={vs[:transcript]} class="font-label text-[9px] text-[#adaaaa]/60 italic truncate">
                "{String.slice(to_string(vs.transcript), 0, 60)}"
              </div>
            </div>
          </div>
        </div>

        <!-- Registry Summary -->
        <div :if={@agents != []} class="grid grid-cols-2 md:grid-cols-4 gap-4">
          <.hud_stat label="TOTAL_AGENTS" value={to_string(length(@agents))} />
          <.hud_stat
            label="MODELS_USED"
            value={to_string(@agents |> Enum.map(& &1.model) |> Enum.uniq() |> Enum.reject(&is_nil/1) |> length())}
            color="secondary"
          />
          <.hud_stat
            label="DENIED_TOOLS"
            value={to_string(Enum.count(@agents, &(&1.denied_tools != [])))}
            color="tertiary"
          />
          <.hud_stat label="SOURCE" value=".claude/agents/" />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Data loading
  # ---------------------------------------------------------------------------

  defp load_agents do
    dir = agents_dir()

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".yml"))
      |> Enum.map(&parse_agent_yaml(Path.join(dir, &1)))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.name)
    else
      []
    end
  rescue
    _ -> []
  end

  defp parse_agent_yaml(path) do
    content = File.read!(path)

    # Split on YAML front matter separator
    {front_matter, system_prompt} =
      case String.split(content, "\n---\n", parts: 2) do
        [fm, sp] -> {fm, String.trim(sp)}
        [fm] -> {fm, nil}
      end

    case YamlElixir.read_from_string(front_matter) do
      {:ok, data} when is_map(data) ->
        %{
          name: data["name"] || Path.basename(path, ".yml"),
          description: data["description"] |> maybe_trim(),
          model: data["model"],
          capabilities: data["capabilities"] || [],
          denied_tools: data["denied_tools"] || [],
          system_prompt: system_prompt
        }

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp maybe_trim(nil), do: nil
  defp maybe_trim(s) when is_binary(s), do: String.trim(s)
  defp maybe_trim(other), do: other

  # ---------------------------------------------------------------------------
  # Name formatting — "coder-backend" → "Coder Backend"
  # ---------------------------------------------------------------------------

  defp humanize_name(name) do
    name
    |> String.replace(~r/[-_]/, " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp nerv_role_badge(name) do
    cond do
      String.contains?(name, "coder") -> "bg-[#00eefc]/10 text-[#00eefc] border border-[#00eefc]/20"
      String.contains?(name, "reviewer") or String.contains?(name, "review") -> "bg-[#ffa44c]/10 text-[#ffa44c] border border-[#ffa44c]/20"
      String.contains?(name, "architect") -> "bg-[#00eefc]/10 text-[#00eefc] border border-[#00eefc]/20"
      String.contains?(name, "researcher") or String.contains?(name, "research") -> "bg-[#ff725e]/10 text-[#ff725e] border border-[#ff725e]/20"
      String.contains?(name, "analyst") -> "bg-[#ffa44c]/10 text-[#ffa44c] border border-[#ffa44c]/20"
      true -> "bg-[#494847]/20 text-[#adaaaa] border border-[#494847]/30"
    end
  end

  defp role_label(name) do
    cond do
      String.contains?(name, "coder") -> "coder"
      String.contains?(name, "reviewer") or String.contains?(name, "review") -> "reviewer"
      String.contains?(name, "architect") -> "architect"
      String.contains?(name, "researcher") or String.contains?(name, "research") -> "researcher"
      String.contains?(name, "analyst") -> "analyst"
      String.contains?(name, "sweeper") -> "ops"
      String.contains?(name, "controller") -> "ops"
      true -> "agent"
    end
  end

  defp voice_status_badge("listening"), do: "bg-[#00eefc]/10 text-[#00eefc] border border-[#00eefc]/20"
  defp voice_status_badge("processing"), do: "bg-[#ffa44c]/10 text-[#ffa44c] border border-[#ffa44c]/20"
  defp voice_status_badge(_), do: "bg-[#494847]/20 text-[#adaaaa] border border-[#494847]/30"
end
