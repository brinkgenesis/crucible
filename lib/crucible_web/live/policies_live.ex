defmodule CrucibleWeb.PoliciesLive do
  @moduledoc """
  LiveView for managing workspace execution policies.

  Displays per-workspace policy settings (allowed models, cost limits, and
  approval thresholds) and provides inline editing with real-time validation.
  """

  use CrucibleWeb, :live_view

  alias Crucible.{AuditLog, WorkspaceProfiles}
  alias Crucible.Schema.WorkspaceProfile

  @doc """
  Loads all workspaces and initializes the page with no active edit form.
  """
  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Policies",
       current_path: "/policies",
       workspaces: WorkspaceProfiles.list_workspaces(),
       editing: nil,
       form: nil
     )}
  end

  @doc """
  Handles UI events for policy management.

  ## Events

    * `"edit_policy"` — opens the inline edit form for the workspace matching `id`
    * `"cancel_edit"` — closes the edit form without saving
    * `"validate_policy"` — validates policy params on each keystroke
    * `"save_policy"` — persists the updated policy and refreshes the workspace list
  """
  @impl true
  def handle_event("edit_policy", %{"id" => id}, socket) do
    case find_workspace(socket.assigns.workspaces, id) do
      %WorkspaceProfile{} = ws ->
        changeset = WorkspaceProfile.policy_changeset(ws, %{})
        {:noreply, assign(socket, editing: ws, form: to_form(changeset, as: "policy"))}

      _ ->
        {:noreply, put_flash(socket, :error, "Workspace not found")}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing: nil, form: nil)}
  end

  def handle_event("validate_policy", %{"policy" => params}, socket) do
    changeset =
      socket.assigns.editing
      |> WorkspaceProfile.policy_changeset(normalize_policy_params(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: "policy"))}
  end

  def handle_event("save_policy", %{"policy" => params}, socket) do
    ws = socket.assigns.editing

    case WorkspaceProfiles.update_workspace(ws, normalize_policy_params(params)) do
      {:ok, _ws} ->
        AuditLog.log("policy", ws.id, "updated", %{fields: Map.keys(normalize_policy_params(params))}, actor: "liveview:PoliciesLive")

        {:noreply,
         socket
         |> assign(
           workspaces: WorkspaceProfiles.list_workspaces(),
           editing: nil,
           form: nil
         )
         |> put_flash(:info, "Policy updated")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "policy"))}
    end
  end

  defp find_workspace(workspaces, id) do
    Enum.find(workspaces, &(&1.id == id))
  end

  defp normalize_policy_params(params) do
    allowed_models =
      (params["allowed_models"] || "")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    %{
      allowed_models: allowed_models,
      cost_limit_usd: params["cost_limit_usd"],
      approval_threshold: params["approval_threshold"]
    }
  end

  @doc """
  Renders the policies dashboard with per-workspace cards and inline edit forms.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <div class="flex flex-col md:flex-row md:items-end justify-between gap-4 mb-2">
          <div>
            <h1 class="text-3xl font-headline font-bold text-[#ffa44c] tracking-tighter uppercase">
              EXECUTION_POLICIES
            </h1>
            <p class="font-mono text-xs text-[#00eefc] opacity-70 mt-1 tracking-widest">
              MODEL_ALLOWLISTS // COST_LIMITS // APPROVAL_GATES
            </p>
          </div>
          <div class="flex gap-2">
            <.hud_stat label="WORKSPACES" value={length(@workspaces)} color="primary" />
          </div>
        </div>

        <div :if={@workspaces == []} class="font-mono text-[11px] text-[#494847] py-8 text-center">
          NO_WORKSPACES_CONFIGURED — CREATE ONE AT /workspaces FIRST
        </div>

        <div :for={ws <- @workspaces} class="space-y-2">
          <.hud_card>
            <div class="flex items-center justify-between mb-4">
              <.hud_header icon="shield" label={"Policy: #{ws.name}"} class="mb-0" />
              <.tactical_button
                :if={@editing == nil || @editing.id != ws.id}
                variant="ghost"
                phx-click="edit_policy"
                phx-value-id={ws.id}
              >
                EDIT_POLICY
              </.tactical_button>
            </div>

            <div :if={@editing == nil || @editing.id != ws.id} class="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div class="p-3 bg-surface-container-high border-l-2 border-[#00eefc]/50">
                <div class="text-[9px] font-mono text-[#00eefc]/70">ALLOWED_MODELS</div>
                <div class="text-sm font-mono text-white mt-1">
                  {if ws.allowed_models == [] or ws.allowed_models == nil,
                    do: "ALL (no restriction)",
                    else: Enum.join(ws.allowed_models, ", ")}
                </div>
              </div>
              <div class="p-3 bg-surface-container-high border-l-2 border-[#ffa44c]/50">
                <div class="text-[9px] font-mono text-[#ffa44c]/70">COST_LIMIT_USD</div>
                <div class="text-xl font-bold font-mono text-white">
                  {if ws.cost_limit_usd, do: "$#{ws.cost_limit_usd}", else: "UNLIMITED"}
                </div>
              </div>
              <div class="p-3 bg-surface-container-high border-l-2 border-[#ff725e]/50">
                <div class="text-[9px] font-mono text-[#ff725e]/70">APPROVAL_THRESHOLD</div>
                <div class="text-xl font-bold font-mono text-white">
                  {if ws.approval_threshold, do: "Complexity >= #{ws.approval_threshold}", else: "NONE"}
                </div>
              </div>
            </div>

            <.form
              :if={@editing != nil && @editing.id == ws.id}
              for={@form}
              phx-submit="save_policy"
              phx-change="validate_policy"
              class="space-y-4"
            >
              <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
                <div>
                  <label class="block text-[9px] font-mono text-[#00eefc]/70 mb-1">ALLOWED_MODELS (comma-separated)</label>
                  <input
                    type="text"
                    name="policy[allowed_models]"
                    value={Enum.join(@form[:allowed_models].value || [], ", ")}
                    placeholder="opus, sonnet, haiku"
                    class="w-full bg-surface-container-highest border border-[#494847] text-white font-mono text-xs px-3 py-2 focus:border-[#00eefc] focus:outline-none"
                  />
                </div>
                <div>
                  <label class="block text-[9px] font-mono text-[#ffa44c]/70 mb-1">COST_LIMIT_USD</label>
                  <input
                    type="text"
                    name="policy[cost_limit_usd]"
                    value={@form[:cost_limit_usd].value}
                    placeholder="50.00"
                    class={["w-full bg-surface-container-highest border text-white font-mono text-xs px-3 py-2 focus:outline-none",
                      if(@form[:cost_limit_usd].errors != [], do: "border-[#ff725e] focus:border-[#ff725e]", else: "border-[#494847] focus:border-[#ffa44c]")]}
                  />
                  <p :for={{msg, _} <- @form[:cost_limit_usd].errors} class="text-[9px] font-mono text-[#ff725e] mt-1">{msg}</p>
                </div>
                <div>
                  <label class="block text-[9px] font-mono text-[#ff725e]/70 mb-1">APPROVAL_THRESHOLD (1-10)</label>
                  <input
                    type="text"
                    name="policy[approval_threshold]"
                    value={@form[:approval_threshold].value}
                    placeholder="7"
                    class={["w-full bg-surface-container-highest border text-white font-mono text-xs px-3 py-2 focus:outline-none",
                      if(@form[:approval_threshold].errors != [], do: "border-[#ff725e] focus:border-[#ff725e]", else: "border-[#494847] focus:border-[#ff725e]")]}
                  />
                  <p :for={{msg, _} <- @form[:approval_threshold].errors} class="text-[9px] font-mono text-[#ff725e] mt-1">{msg}</p>
                </div>
              </div>
              <div class="flex gap-2">
                <.tactical_button type="submit">SAVE_POLICY</.tactical_button>
                <.tactical_button variant="ghost" type="button" phx-click="cancel_edit">CANCEL</.tactical_button>
              </div>
            </.form>
          </.hud_card>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
