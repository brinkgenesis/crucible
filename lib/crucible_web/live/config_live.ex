defmodule CrucibleWeb.ConfigLive do
  @moduledoc """
  LiveView for the system configuration page.

  Presents a tabbed interface with three sections:

    * **Claude Flow** — read-only display of the `.claude-flow/config.yaml` YAML
      config, rendered as a recursive tree.
    * **Environment** — editable view of the project `.env` file. Variables are
      categorised (Budget, API Keys, Infrastructure, Feature Flags) and sensitive
      values are masked with a password input.
    * **Budget Limits** — form-validated editor for the three budget caps
      (`DAILY_BUDGET_LIMIT_USD`, `AGENT_BUDGET_LIMIT_USD`, `TASK_BUDGET_LIMIT_USD`)
      backed by `BudgetLimits` changeset validation.

  All writes go directly to the `.env` file on disk; budget defaults are read
  from application config at mount time.
  """

  use CrucibleWeb, :live_view

  alias Crucible.AuditLog
  alias Crucible.Schema.BudgetLimits

  @doc """
  Mounts the LiveView, initialising default assigns (active tab, save status)
  and loading Claude Flow config, environment variables, and budget limits.
  """
  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Configuration",
       current_path: "/config",
       active_tab: "claude-flow",
       save_status: nil,
       budget_form: nil
     )
     |> load_data()}
  end

  @doc """
  Handles all `phx-click` and `phx-submit` events for the configuration page.

  ## Events

    * `"switch_tab"` — switches the active tab and clears any save status banner.
    * `"update_env"` — writes a single environment variable to the `.env` file.
    * `"validate_budget"` — runs changeset validation on the budget form without saving.
    * `"save_budget"` — validates and persists all three budget limits to `.env`.
  """
  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab, save_status: nil)}
  end

  def handle_event("update_env", %{"key" => key, "value" => value}, socket) do
    with :ok <- validate_env_key(key),
         :ok <- validate_env_value(value),
         :ok <- write_env_var(key, value) do
      AuditLog.log("env_var", key, "updated", %{key: key}, actor: "liveview:ConfigLive")
      {:noreply, assign(socket, save_status: {:ok, "Saved #{key}"}) |> load_env_vars()}
    else
      {:error, reason} ->
        {:noreply, assign(socket, save_status: {:error, reason})}
    end
  end

  def handle_event("validate_budget", %{"budget" => params}, socket) do
    changeset =
      %BudgetLimits{}
      |> BudgetLimits.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, budget_form: to_form(changeset, as: "budget"))}
  end

  def handle_event("save_budget", %{"budget" => params}, socket) do
    changeset = BudgetLimits.changeset(%BudgetLimits{}, params)

    if changeset.valid? do
      limits = Ecto.Changeset.apply_changes(changeset)

      updates = [
        {"DAILY_BUDGET_LIMIT_USD", Float.to_string(limits.daily_limit_usd)},
        {"AGENT_BUDGET_LIMIT_USD", Float.to_string(limits.agent_limit_usd)},
        {"TASK_BUDGET_LIMIT_USD", Float.to_string(limits.task_limit_usd)}
      ]

      results = Enum.map(updates, fn {k, v} -> write_env_var(k, v) end)

      if Enum.all?(results, &(&1 == :ok)) do
        AuditLog.log(
          "budget",
          "limits",
          "updated",
          %{
            daily: limits.daily_limit_usd,
            agent: limits.agent_limit_usd,
            task: limits.task_limit_usd
          },
          actor: "liveview:ConfigLive"
        )

        {:noreply,
         socket
         |> assign(save_status: {:ok, "Budget limits saved"})
         |> load_env_vars()
         |> load_budget_limits()}
      else
        {:noreply, assign(socket, save_status: {:error, "Failed to save some budget limits"})}
      end
    else
      {:noreply,
       assign(socket,
         budget_form: to_form(Map.put(changeset, :action, :validate), as: "budget")
       )}
    end
  end

  # ---------------------------------------------------------------------------
  # Data loading
  # ---------------------------------------------------------------------------

  defp load_data(socket) do
    socket |> load_claude_flow() |> load_env_vars() |> load_budget_limits()
  end

  defp load_claude_flow(socket) do
    path = claude_flow_config_path()

    {raw, parsed} =
      safe_call(
        fn ->
          raw = File.read!(path)
          parsed = YamlElixir.read_from_string!(raw)
          {raw, parsed}
        end,
        {"", %{}}
      )

    assign(socket, claude_flow_raw: raw, claude_flow_config: parsed)
  end

  defp load_env_vars(socket) do
    vars =
      safe_call(
        fn ->
          env_file_path()
          |> File.read!()
          |> String.split("\n", trim: true)
          |> Enum.reject(&(String.starts_with?(&1, "#") or &1 == ""))
          |> Enum.map(&parse_env_line/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&categorize_env_var/1)
        end,
        []
      )

    assign(socket, env_vars: vars)
  end

  defp load_budget_limits(socket) do
    config = Application.get_env(:crucible, :orchestrator, [])

    limits = %{
      daily: Keyword.get(config, :daily_budget_usd, 100.0),
      agent: Keyword.get(config, :agent_budget_usd, 10.0),
      task: Keyword.get(config, :task_budget_usd, 50.0)
    }

    budget_form =
      %BudgetLimits{}
      |> BudgetLimits.changeset(%{
        daily_limit_usd: limits.daily,
        agent_limit_usd: limits.agent,
        task_limit_usd: limits.task
      })
      |> to_form(as: "budget")

    assign(socket, budget_limits: limits, budget_form: budget_form)
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @doc """
  Renders the configuration page with a tabbed layout (Claude Flow, Environment,
  Budget Limits), a save-status banner, and the currently active tab's content.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <.hud_header icon="settings" label="CONFIGURATION" />
        
    <!-- Save status -->
        <div
          :if={@save_status}
          class={[
            "flex items-center gap-3 px-4 py-2.5 font-mono text-xs rounded border",
            save_hud_class(@save_status)
          ]}
        >
          <span class="material-symbols-outlined text-sm">{save_hud_icon(@save_status)}</span>
          <span>{save_status_text(@save_status)}</span>
        </div>
        
    <!-- NERV Tabs -->
        <div class="flex border-b border-[#ffa44c]/10">
          <button
            :for={
              {tab, label, icon} <- [
                {"claude-flow", "CLAUDE_FLOW", "hub"},
                {"environment", "ENVIRONMENT", "terminal"},
                {"budget", "BUDGET_LIMITS", "payments"}
              ]
            }
            phx-click="switch_tab"
            phx-value-tab={tab}
            class={[
              "flex items-center gap-2 px-4 py-2.5 font-mono text-[10px] tracking-widest uppercase transition-colors border-b-2 -mb-[1px]",
              if(@active_tab == tab,
                do: "text-[#00eefc] border-[#00eefc] bg-[#00eefc]/5",
                else:
                  "text-[#e0e0e0]/40 border-transparent hover:text-[#e0e0e0]/60 hover:bg-[#ffa44c]/5"
              )
            ]}
          >
            <span class="material-symbols-outlined text-sm">{icon}</span>
            {label}
          </button>
        </div>
        
    <!-- Claude Flow tab (read-only) -->
        <div :if={@active_tab == "claude-flow"} class="space-y-4">
          <div :if={@claude_flow_config == %{}} class="text-center py-8 text-[#e0e0e0]/30">
            <span class="material-symbols-outlined text-4xl opacity-30 block mb-3">description</span>
            <p class="font-mono text-xs">NO_CONFIG_FOUND</p>
          </div>
          <.hud_card :for={{section, values} <- @claude_flow_config}>
            <div class="font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 mb-3">
              {section}
            </div>
            <.config_tree values={values} depth={0} />
          </.hud_card>
        </div>
        
    <!-- Environment tab -->
        <div :if={@active_tab == "environment"} class="space-y-4">
          <div :if={@env_vars == []} class="text-center py-8 text-[#e0e0e0]/30">
            <span class="material-symbols-outlined text-4xl opacity-30 block mb-3">data_object</span>
            <p class="font-mono text-[10px] text-neutral-500">NO_ENV_FILE_FOUND</p>
          </div>
          <.hud_card :for={{category, vars} <- group_env_vars(@env_vars)}>
            <div class="font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 mb-3">
              {category}
            </div>
            <div class="space-y-2">
              <form
                :for={var <- vars}
                phx-submit="update_env"
                class="flex items-center gap-3"
              >
                <span
                  class="font-mono text-[11px] text-[#00eefc]/60 w-64 shrink-0 truncate"
                  title={var.key}
                >
                  {var.key}
                </span>
                <input type="hidden" name="key" value={var.key} />
                <input
                  type={if var.sensitive, do: "password", else: "text"}
                  name="value"
                  value={var.value}
                  class="flex-1 bg-surface-container border border-[#ffa44c]/20 text-[#e0e0e0] font-mono text-[11px] px-3 py-1.5 rounded focus:border-[#00eefc]/50 focus:outline-none"
                />
                <button
                  type="submit"
                  class="px-2 py-1 text-[#00FF41]/60 hover:text-[#00FF41] hover:bg-[#00FF41]/10 rounded transition-colors"
                >
                  <span class="material-symbols-outlined text-sm">check</span>
                </button>
              </form>
            </div>
          </.hud_card>
        </div>
        
    <!-- Budget tab -->
        <div :if={@active_tab == "budget"}>
          <.form for={@budget_form} phx-submit="save_budget" phx-change="validate_budget">
            <.hud_card accent="primary">
              <div class="font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 mb-4">
                BUDGET LIMITS (USD)
              </div>
              <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
                <div class="border-l-2 border-[#ffa44c] pl-3">
                  <div class="font-mono text-[10px] tracking-widest uppercase text-[#ffa44c]/60 mb-1">
                    Daily Limit
                  </div>
                  <input
                    type="number"
                    name="budget[daily_limit_usd]"
                    value={@budget_form[:daily_limit_usd].value}
                    step="0.01"
                    min="0"
                    class={[
                      "w-full bg-surface-container border font-mono text-lg px-3 py-2 rounded focus:outline-none",
                      if(@budget_form[:daily_limit_usd].errors != [],
                        do: "border-[#ff725e] text-[#ff725e]",
                        else: "border-[#ffa44c]/20 text-[#ffa44c] focus:border-[#ffa44c]/50"
                      )
                    ]}
                  />
                  <p
                    :for={{msg, _} <- @budget_form[:daily_limit_usd].errors}
                    class="text-[9px] font-mono text-[#ff725e] mt-1"
                  >
                    {msg}
                  </p>
                </div>
                <div class="border-l-2 border-[#00eefc] pl-3">
                  <div class="font-mono text-[10px] tracking-widest uppercase text-[#00eefc]/60 mb-1">
                    Per Agent
                  </div>
                  <input
                    type="number"
                    name="budget[agent_limit_usd]"
                    value={@budget_form[:agent_limit_usd].value}
                    step="0.01"
                    min="0"
                    class={[
                      "w-full bg-surface-container border font-mono text-lg px-3 py-2 rounded focus:outline-none",
                      if(@budget_form[:agent_limit_usd].errors != [],
                        do: "border-[#ff725e] text-[#ff725e]",
                        else: "border-[#00eefc]/20 text-[#00eefc] focus:border-[#00eefc]/50"
                      )
                    ]}
                  />
                  <p
                    :for={{msg, _} <- @budget_form[:agent_limit_usd].errors}
                    class="text-[9px] font-mono text-[#ff725e] mt-1"
                  >
                    {msg}
                  </p>
                </div>
                <div class="border-l-2 border-[#ff725e] pl-3">
                  <div class="font-mono text-[10px] tracking-widest uppercase text-[#ff725e]/60 mb-1">
                    Per Task
                  </div>
                  <input
                    type="number"
                    name="budget[task_limit_usd]"
                    value={@budget_form[:task_limit_usd].value}
                    step="0.01"
                    min="0"
                    class={[
                      "w-full bg-surface-container border font-mono text-lg px-3 py-2 rounded focus:outline-none",
                      if(@budget_form[:task_limit_usd].errors != [],
                        do: "border-[#ff725e] text-[#ff725e]",
                        else: "border-[#ff725e]/20 text-[#ff725e] focus:border-[#ff725e]/50"
                      )
                    ]}
                  />
                  <p
                    :for={{msg, _} <- @budget_form[:task_limit_usd].errors}
                    class="text-[9px] font-mono text-[#ff725e] mt-1"
                  >
                    {msg}
                  </p>
                </div>
              </div>
              <div class="mt-4">
                <.tactical_button variant="primary" type="submit">
                  <span class="material-symbols-outlined text-sm mr-1">save</span> SAVE BUDGET
                </.tactical_button>
              </div>
            </.hud_card>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Config tree component (recursive display)
  # ---------------------------------------------------------------------------

  attr :values, :any, required: true
  attr :depth, :integer, default: 0

  defp config_tree(%{values: values} = assigns) when is_map(values) do
    items = Enum.sort_by(values, &elem(&1, 0))
    assigns = assign(assigns, items: items)

    ~H"""
    <div class={["space-y-1", @depth > 0 && "ml-4 border-l border-[#ffa44c]/10 pl-3"]}>
      <div :for={{key, val} <- @items}>
        <div :if={is_map(val) or is_list(val)}>
          <div class="font-mono text-[10px] font-bold text-[#ffa44c]/50 mt-2 tracking-wider uppercase">
            {key}
          </div>
          <.config_tree values={val} depth={@depth + 1} />
        </div>
        <div :if={not is_map(val) and not is_list(val)} class="flex items-center gap-3 py-0.5">
          <span class="font-mono text-[11px] text-[#e0e0e0]/40 w-40 shrink-0">{key}</span>
          <span class="font-mono text-[11px] text-[#00eefc]/70">{inspect(val)}</span>
        </div>
      </div>
    </div>
    """
  end

  defp config_tree(%{values: values} = assigns) when is_list(values) do
    ~H"""
    <div class={["ml-4 border-l border-[#ffa44c]/10 pl-3", @depth > 0 && ""]}>
      <div :for={{item, i} <- Enum.with_index(@values)} class="flex items-center gap-2 py-0.5">
        <span class="font-mono text-[10px] text-[#ffa44c]/20">{i}.</span>
        <span :if={is_map(item)}>
          <.config_tree values={item} depth={@depth + 1} />
        </span>
        <span :if={not is_map(item)} class="font-mono text-[11px] text-[#00eefc]/70">
          {inspect(item)}
        </span>
      </div>
    </div>
    """
  end

  defp config_tree(assigns) do
    ~H"""
    <span class="font-mono text-[11px] text-[#00eefc]/70">{inspect(@values)}</span>
    """
  end

  # ---------------------------------------------------------------------------
  # Env var helpers
  # ---------------------------------------------------------------------------

  defp parse_env_line(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] -> %{key: String.trim(key), value: String.trim(value)}
      _ -> nil
    end
  end

  defp categorize_env_var(%{key: key} = var) do
    category =
      cond do
        String.contains?(key, "API_KEY") or String.contains?(key, "TOKEN") or
            String.contains?(key, "SECRET") ->
          "API Keys"

        String.contains?(key, "BUDGET") or String.contains?(key, "COST") ->
          "Budget"

        String.contains?(key, "PORT") or String.contains?(key, "HOST") or
          String.contains?(key, "URL") or String.contains?(key, "CORS") ->
          "Infrastructure"

        String.contains?(key, "ENABLE") or String.contains?(key, "EXPERIMENTAL") or
            String.contains?(key, "CANARY") ->
          "Feature Flags"

        true ->
          "Other"
      end

    sensitive =
      String.contains?(key, "API_KEY") or String.contains?(key, "TOKEN") or
        String.contains?(key, "SECRET") or String.contains?(key, "PASSWORD")

    Map.merge(var, %{category: category, sensitive: sensitive})
  end

  defp group_env_vars(vars) do
    order = ["Budget", "API Keys", "Infrastructure", "Feature Flags", "Other"]

    vars
    |> Enum.group_by(& &1.category)
    |> Enum.sort_by(fn {cat, _} -> Enum.find_index(order, &(&1 == cat)) || 99 end)
  end

  defp write_env_var(key, value) do
    path = env_file_path()

    if File.exists?(path) do
      content = File.read!(path)
      lines = String.split(content, "\n")

      {found, updated} =
        Enum.map_reduce(lines, false, fn line, found ->
          if String.starts_with?(line, "#{key}=") do
            {"#{key}=#{value}", true}
          else
            {line, found}
          end
        end)

      new_content =
        if found do
          Enum.join(updated, "\n")
        else
          content <> "\n#{key}=#{value}"
        end

      File.write!(path, new_content)
      :ok
    else
      File.write!(path, "#{key}=#{value}\n")
      :ok
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # Save status helpers
  # ---------------------------------------------------------------------------

  defp save_hud_class({:ok, _}), do: "text-[#00FF41] border-[#00FF41]/20 bg-[#00FF41]/5"
  defp save_hud_class({:error, _}), do: "text-[#ff7351] border-[#ff7351]/20 bg-[#ff7351]/5"
  defp save_hud_class(_), do: "text-[#e0e0e0]/50 border-[#e0e0e0]/10"

  defp save_hud_icon({:ok, _}), do: "check_circle"
  defp save_hud_icon({:error, _}), do: "error"
  defp save_hud_icon(_), do: "info"

  defp save_status_text({:ok, msg}), do: msg
  defp save_status_text({:error, msg}), do: msg
  defp save_status_text(_), do: ""

  # ---------------------------------------------------------------------------
  # Paths and utils
  # ---------------------------------------------------------------------------

  defp validate_env_key(key) when is_binary(key) do
    if Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, key) do
      :ok
    else
      {:error, "Invalid key: must be UPPER_SNAKE_CASE"}
    end
  end

  defp validate_env_key(_), do: {:error, "Invalid key"}

  defp validate_env_value(value) when is_binary(value) do
    if String.contains?(value, "\n") do
      {:error, "Value must not contain newlines"}
    else
      :ok
    end
  end

  defp validate_env_value(_), do: {:error, "Invalid value"}

  defp claude_flow_config_path do
    config = Application.get_env(:crucible, :orchestrator, [])
    repo_root = Keyword.get(config, :repo_root, File.cwd!())
    Path.join(repo_root, ".claude-flow/config.yaml")
  end

  defp env_file_path do
    config = Application.get_env(:crucible, :orchestrator, [])
    repo_root = Keyword.get(config, :repo_root, File.cwd!())
    Path.join(repo_root, ".env")
  end
end
