defmodule CrucibleWeb.KanbanLive do
  @moduledoc """
  LiveView for the kanban board UI.

  Displays workflow cards across six columns (`ideation → unassigned → todo →
  in_progress → review → done`). Cards advance columns automatically when their
  linked workflow run changes status, and can be repositioned manually via
  drag-and-drop (handled by the `KanbanDrag` client hook sending `move_card`
  events).

  Moving a card into the `todo` column triggers the associated workflow via the
  Orchestrator. Real-time updates arrive through `Phoenix.PubSub` on the
  `kanban:cards` topic, supplemented by a periodic `RefreshTimer` poll.
  """

  use CrucibleWeb, :live_view

  alias Crucible.Kanban
  alias Crucible.{CostEventReader, Orchestrator, TraceReader, WorkflowStore}
  alias CrucibleWeb.Live.RefreshTimer
  alias Phoenix.LiveView.JS

  require Logger

  @columns ~w(ideation unassigned todo in_progress review done)
  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    timer =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Crucible.PubSub, "kanban:cards")
        RefreshTimer.start(@refresh_interval)
      end

    {:ok,
     socket
     |> assign(
       page_title: "Kanban",
       refresh_timer: timer,
       current_path: "/kanban",
       columns: @columns,
       execution_mode: "sdk",
       show_archived: false,
       ci_only: false,
       show_add_form: false,
       new_card_title: "",
       # Card detail modal state
       detail_card: nil,
       detail_summary: nil,
       detail_sessions: [],
       detail_agents: [],
       detail_logs: %{},
       detail_tab: "phases",
       card_history: [],
       plan_popup: nil,
       detail_plan: nil,
       workspaces: Crucible.WorkspaceProfiles.list_workspaces(),
       selected_cards: MapSet.new()
     )
     |> load_cards()}
  end

  @impl true
  def terminate(_reason, socket) do
    RefreshTimer.cancel(socket.assigns[:refresh_timer])
  end

  @doc """
  Handles incoming messages: `:refresh` timer ticks, PubSub card events,
  and kanban broadcast updates — all trigger a card reload from the database.
  """
  @impl true
  def handle_info(:refresh, socket) do
    socket = load_cards(socket)
    timer = RefreshTimer.tick(socket.assigns[:refresh_timer], true)
    {:noreply, assign(socket, refresh_timer: timer)}
  end

  def handle_info({:kanban_update, _}, socket) do
    timer = RefreshTimer.reset(socket.assigns[:refresh_timer])
    {:noreply, assign(load_cards(socket), refresh_timer: timer)}
  end

  def handle_info({event, _card}, socket)
      when event in [
             :card_created,
             :card_updated,
             :card_moved,
             :card_archived,
             :card_restored,
             :card_deleted
           ],
      do: {:noreply, load_cards(socket)}

  @impl true
  def handle_event("move_card", %{"id" => id, "column" => column}, socket) do
    adapter = kanban_adapter()

    case adapter.move_card(id, column) do
      {:ok, card} ->
        # Clear stale run_id when moving back to unassigned so re-trigger works cleanly
        if column == "unassigned" && card.run_id do
          adapter.update_card(card.id, %{run_id: nil})
        end

        # Log subtask completion on parent card
        if column == "done" && Map.get(card, :parent_card_id) do
          adapter.log_card_event(Map.get(card, :parent_card_id), "card_subtask_done", %{
            subtask_id: card.id,
            subtask_title: Map.get(card, :title)
          })
        end

        socket =
          if column == "todo", do: maybe_trigger_workflow(socket, card, adapter), else: socket

        {:noreply, load_cards(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Move failed: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_card_selected", %{"id" => id}, socket) do
    selected = socket.assigns.selected_cards

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, selected_cards: selected)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, selected_cards: MapSet.new())}
  end

  # Fires every selected unassigned card into :todo concurrently.
  # Each card still goes through `maybe_trigger_workflow`, which enforces the
  # same guards (no double-trigger, sub-cards skipped) as drag-and-drop.
  def handle_event("execute_selected", _params, socket) do
    adapter = kanban_adapter()
    unassigned = Map.get(socket.assigns.cards_by_column, "unassigned", [])
    selected_ids = socket.assigns.selected_cards

    targets =
      unassigned
      |> Enum.filter(fn c -> MapSet.member?(selected_ids, to_string(c.id)) end)

    socket =
      Enum.reduce(targets, socket, fn card, acc ->
        case adapter.move_card(card.id, "todo") do
          {:ok, moved} ->
            maybe_trigger_workflow(acc, moved, adapter)

          {:error, reason} ->
            Logger.warning("KanbanLive.execute_selected move failed: #{inspect(reason)}")
            put_flash(acc, :error, "Move failed for card #{card.id}: #{inspect(reason)}")
        end
      end)

    count = length(targets)

    flash_msg =
      case count do
        0 -> "No selected cards to execute"
        1 -> "Executing 1 card"
        n -> "Executing #{n} cards concurrently"
      end

    {:noreply,
     socket
     |> assign(selected_cards: MapSet.new())
     |> put_flash(:info, flash_msg)
     |> load_cards()}
  end

  def handle_event("archive_card", %{"id" => id}, socket) do
    adapter = kanban_adapter()

    case adapter.archive_card(id) do
      {:ok, _} ->
        {:noreply, load_cards(socket) |> put_flash(:info, "Card archived")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Archive failed: #{inspect(reason)}")}
    end
  end

  def handle_event("restore_card", %{"id" => id}, socket) do
    adapter = kanban_adapter()

    case adapter.restore_card(id) do
      {:ok, _} ->
        {:noreply, load_cards(socket) |> put_flash(:info, "Card restored")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Restore failed: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_archived", _params, socket) do
    {:noreply, assign(socket, show_archived: !socket.assigns.show_archived) |> load_cards()}
  end

  def handle_event("toggle_ci_filter", _params, socket) do
    {:noreply, assign(socket, ci_only: !socket.assigns.ci_only) |> load_cards()}
  end

  def handle_event("show_card_detail", %{"id" => id}, socket) do
    cards = all_cards(socket)
    card = Enum.find(cards, &(to_string(&1.id) == id))

    if card do
      {summary, sessions, agents, logs} = load_card_detail(card)
      metadata = Map.get(card, :metadata) || %{}
      plan_note_path = metadata["planNote"]

      plan_content =
        if plan_note_path do
          case Crucible.VaultPlanStore.read_note(plan_note_path) do
            {:error, reason} ->
              require Logger

              Logger.warning(
                "[KanbanLive] plan read failed: path=#{plan_note_path} reason=#{inspect(reason)}"
              )

              nil
          end
        else
          require Logger
          Logger.debug("[KanbanLive] no planNote in metadata for card #{id}")
          nil
        end

      default_tab = if plan_content, do: "plan", else: "phases"

      {:noreply,
       assign(socket,
         detail_card: card,
         detail_summary: summary,
         detail_sessions: sessions,
         detail_agents: agents,
         detail_logs: logs,
         detail_tab: default_tab,
         detail_plan: plan_content
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_card_detail", _params, socket) do
    {:noreply, assign(socket, detail_card: nil)}
  end

  def handle_event("open_plan_popup", %{"path" => path, "card_id" => _card_id}, socket) do
    popup =
      case Crucible.VaultPlanStore.read_note(path) do
        {:error, _} -> nil
      end

    {:noreply, assign(socket, plan_popup: popup)}
  end

  def handle_event("close_plan_popup", _params, socket) do
    {:noreply, assign(socket, plan_popup: nil)}
  end

  def handle_event("detail_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, detail_tab: tab)}
  end

  def handle_event("set_execution_mode", %{"mode" => mode}, socket)
      when mode in ["subscription", "sdk", "api"] do
    {:noreply, assign(socket, execution_mode: mode)}
  end

  def handle_event("toggle_add_form", _params, socket) do
    {:noreply, assign(socket, show_add_form: !socket.assigns.show_add_form, new_card_title: "")}
  end

  def handle_event("patrol_scan", _params, socket) do
    case Crucible.PatrolScanner.schedule_scan(window_hours: 24) do
      {:ok, _job} ->
        {:noreply,
         put_flash(socket, :info, "Patrol scan queued — new cards will appear shortly")
         |> load_cards()}
    end
  end

  def handle_event("load_card_history", %{"id" => id}, socket) do
    adapter = kanban_adapter()

    history =
      try do
        case adapter.card_history(id) do
          {:ok, events} -> events
          _ -> []
        end
      rescue
        _ -> []
      end

    {:noreply, assign(socket, detail_tab: "history", card_history: history)}
  end

  def handle_event("create_card", %{"title" => title}, socket) do
    title = String.trim(title)

    if title == "" do
      {:noreply, put_flash(socket, :error, "Card title cannot be empty")}
    else
      adapter = kanban_adapter()

      case adapter.create_card(%{title: title, column: "unassigned"}) do
        {:ok, _card} ->
          {:noreply,
           load_cards(socket)
           |> assign(show_add_form: false, new_card_title: "")
           |> put_flash(:info, "Card created")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("set_card_workspace", %{"workspace_id" => ws_id}, socket) do
    card = socket.assigns[:detail_card]

    if card do
      ws_id = if ws_id == "", do: nil, else: ws_id
      kanban_adapter().update_card(card.id, %{workspace_id: ws_id})
      updated_card = %{card | workspace_id: ws_id}
      {:noreply, assign(socket, detail_card: updated_card) |> load_cards()}
    else
      {:noreply, socket}
    end
  end

  defp maybe_trigger_workflow(socket, card, adapter) do
    metadata = card.metadata || %{}
    refined_for = metadata["refinedForWorkspace"]

    cond do
      # Sub-cards never auto-trigger
      card.parent_card_id ->
        socket

      # Skip if this card's run is still active (prevent double-trigger)
      card.run_id && run_active?(card.run_id) ->
        Logger.debug("KanbanLive: skipping trigger — run #{card.run_id} still active")
        socket

      # Plan was refined for a specific codebase but no workspace selected — warn
      refined_for && is_nil(card.workspace_id) ->
        Logger.warning(
          "KanbanLive: card #{card.id} refined for #{refined_for} but no workspace set"
        )

        put_flash(
          socket,
          :error,
          "This plan was refined for #{refined_for} — select the target workspace before executing"
        )

      # Card has no active run → trigger workflow
      true ->
        trigger_workflow(socket, card, adapter)
    end
  end

  defp run_active?(run_id) do
    case Orchestrator.lookup_run(run_id) do
      {:ok, _pid, _meta} -> true
      :not_found -> false
    end
  end

  defp trigger_workflow(socket, card, adapter) do
    workflow_name = card.workflow || "coding-sprint"

    case WorkflowStore.get(workflow_name) do
      {:ok, workflow_config} ->
        run_id = generate_run_id()
        manifest = build_manifest(run_id, workflow_config, card, socket.assigns.execution_mode)

        case Orchestrator.submit_run(manifest) do
          :ok ->
            adapter.update_card(card.id, %{run_id: run_id})

            adapter.log_card_event(card.id, "card_planned", %{
              workflow: workflow_name,
              run_id: run_id
            })

            Logger.info(
              "KanbanLive: triggered workflow #{workflow_name} for card #{card.id} (run #{run_id})"
            )

            put_flash(socket, :info, "Workflow #{workflow_name} triggered")

          {:error, reason} ->
            Logger.error("KanbanLive: failed to trigger workflow: #{inspect(reason)}")
            put_flash(socket, :error, "Failed to trigger workflow: #{inspect(reason)}")
        end

      {:error, :not_found} ->
        Logger.error("KanbanLive: workflow '#{workflow_name}' not found in WorkflowStore")
        put_flash(socket, :error, "Workflow '#{workflow_name}' not found")
    end
  end

  @doc false
  def build_manifest(run_id, workflow_config, card, execution_mode) do
    plan_note = get_in(card.metadata || %{}, ["planNote"])
    plan_summary = get_in(card.metadata || %{}, ["planSummary"])
    # WorkflowStore configs use "name"; Manifest.validate requires "workflow_name"
    workflow_name = workflow_config["name"] || workflow_config["workflow_name"]

    ws_id = Map.get(card, :workspace_id)

    {workspace_path, default_branch, workspace_name, tech_context} =
      if ws_id do
        case Crucible.WorkspaceProfiles.get_workspace(ws_id) do
          %{repo_path: path, default_branch: branch, name: name, tech_context: tc} ->
            {path, branch || "main", name, tc || ""}

          _ ->
            {nil, "main", nil, ""}
        end
      else
        {nil, "main", nil, ""}
      end

    workflow_config
    |> Map.put("run_id", run_id)
    |> Map.put("workflow_name", workflow_name)
    |> Map.put("status", "pending")
    |> Map.put("execution_type", execution_mode)
    |> Map.put("card_id", card.id)
    |> Map.put("plan_note", plan_note)
    |> Map.put("plan_summary", plan_summary)
    |> Map.put("task_description", card.title)
    |> Map.put("workspace_path", workspace_path)
    |> Map.put("default_branch", default_branch)
    |> Map.put("workspace_name", workspace_name)
    |> Map.put("tech_context", tech_context)
    |> Map.put("created_at", DateTime.utc_now() |> DateTime.to_iso8601())
  end

  defp generate_run_id do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
  end

  defp load_cards(socket) do
    adapter = kanban_adapter()

    cards =
      case adapter.list_cards() do
        {:ok, cards} -> cards
        _ -> []
      end

    # Auto-sync card columns based on linked workflow run status
    cards = sync_card_columns(cards, adapter)

    {active, archived} = Enum.split_with(cards, &(!Map.get(&1, :archived, false)))

    active =
      if socket.assigns[:ci_only] do
        Enum.filter(active, fn card ->
          String.starts_with?(Map.get(card, :title, ""), "[CI]")
        end)
      else
        active
      end

    grouped =
      Enum.group_by(active, fn card ->
        col = Map.get(card, :column, "unassigned")
        if col in @columns, do: col, else: "unassigned"
      end)

    unassigned_ids =
      grouped
      |> Map.get("unassigned", [])
      |> MapSet.new(&to_string(&1.id))

    pruned_selection =
      case socket.assigns[:selected_cards] do
        %MapSet{} = set -> MapSet.intersection(set, unassigned_ids)
        _ -> MapSet.new()
      end

    assign(socket,
      cards_by_column: grouped,
      archived_cards: archived,
      selected_cards: pruned_selection
    )
  end

  # Sync card columns with workflow run status from the DB
  defp sync_card_columns(cards, adapter) do
    Enum.map(cards, fn card ->
      run_id = Map.get(card, :run_id)

      if run_id && run_id != "" do
        expected_column = column_for_run(run_id)

        if expected_column && expected_column != card.column do
          case adapter.move_card(card.id, expected_column, card.version) do
            {:ok, updated} -> updated
            _ -> card
          end
        else
          card
        end
      else
        card
      end
    end)
  end

  defp column_for_run(run_id) do
    status = db_run_status(run_id)

    case status do
      nil -> nil
      s when s in ["pending"] -> "todo"
      s when s in ["running", "in_progress"] -> "in_progress"
      s when s in ["done", "completed"] -> "done"
      s when s in ["review", "pr_shepherd", "pr_review"] -> "review"
      _ -> nil
    end
  end

  defp db_run_status(run_id) do
    import Ecto.Query

    Crucible.Repo.one(
      from(r in Crucible.Schema.WorkflowRun,
        where: r.run_id == ^run_id,
        select: r.status
      )
    )
  rescue
    e in [DBConnection.ConnectionError, Postgrex.Error] ->
      require Logger
      Logger.warning("KanbanLive.db_run_status error: #{Exception.message(e)}")
      nil
  end

  defp kanban_adapter do
    Application.get_env(:crucible, :kanban_adapter, Kanban.DbAdapter)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <div id="kanban-execution-mode-sync" phx-hook="ExecutionModeSync" class="hidden"></div>
        <!-- Toolbar -->
        <div class="flex justify-between items-end border-l-4 border-[#ffa44c] pl-4">
          <div>
            <h1 class="font-headline text-3xl font-bold tracking-tighter text-[#ffa44c] uppercase">
              TACTICAL_PIPELINE
            </h1>
            <p class="font-label text-[10px] text-[#00eefc] tracking-widest uppercase">
              ORCHESTRATION_LAYER //
              <span :if={@execution_mode == "api"} class="text-[#ff725e]">EXEC_API</span>
              <span :if={@execution_mode == "sdk"} class="text-[#00eefc]">EXEC_SDK</span>
              <span :if={@execution_mode == "subscription"} class="text-[#00eefc]">EXEC_TMUX</span>
            </p>
          </div>
          <div class="flex gap-3">
            <button
              :if={MapSet.size(@selected_cards) > 0}
              type="button"
              phx-click="execute_selected"
              class="px-4 py-2 bg-[#00eefc] text-black font-label text-[10px] font-bold uppercase tracking-widest hover:bg-[#00eefc]/80 flex items-center gap-2"
            >
              <.mat_icon name="play_arrow" class="text-sm" /> EXECUTE ({MapSet.size(@selected_cards)})
            </button>
            <button
              :if={MapSet.size(@selected_cards) > 0}
              type="button"
              phx-click="clear_selection"
              class="px-3 py-2 border border-[#494847] text-[#adaaaa] font-label text-[10px] uppercase tracking-widest hover:bg-surface-container-high"
            >
              CLEAR
            </button>
            <.tactical_button phx-click="toggle_add_form">
              <span class="flex items-center gap-2">
                <.mat_icon name="add_box" class="text-sm" /> NEW_TASK
              </span>
            </.tactical_button>
            <.tactical_button variant="ghost" phx-click="toggle_ci_filter">
              <span class={"flex items-center gap-2 #{if @ci_only, do: "text-[#00eefc]", else: ""}"}>
                <.mat_icon name="smart_toy" class="text-sm" />
                {if @ci_only, do: "ALL_CARDS", else: "CI_ONLY"}
              </span>
            </.tactical_button>
            <.tactical_button variant="ghost" phx-click="toggle_archived">
              <span class="flex items-center gap-2">
                <.mat_icon name="inventory_2" class="text-sm" />
                {if @show_archived, do: "HIDE", else: "SHOW"}_ARCHIVE
              </span>
            </.tactical_button>
          </div>
        </div>
        
    <!-- Add card form -->
        <div
          :if={@show_add_form}
          class="bg-surface-container-low border border-[#ffa44c]/20 p-6 hud-border"
        >
          <h3 class="font-headline font-bold text-[#ffa44c] uppercase tracking-widest text-sm mb-4 flex items-center gap-2">
            <.mat_icon name="add_task" class="text-sm" /> NEW_DEPLOYMENT_FORM
          </h3>
          <form phx-submit="create_card" class="space-y-4">
            <div>
              <label class="font-label text-[9px] text-[#ffa44c]/60 uppercase block mb-1">
                Task Title
              </label>
              <input
                type="text"
                name="title"
                value={@new_card_title}
                placeholder="ENTER_OBJECTIVE_NAME..."
                class="w-full bg-surface-container-highest border-b border-[#777575] focus:border-[#00eefc] outline-none text-white p-2 font-body text-xs"
                autofocus
                phx-mounted={JS.focus()}
              />
            </div>
            <div class="flex gap-3">
              <button
                type="button"
                phx-click="toggle_add_form"
                class="flex-1 py-2 border border-[#494847] text-[#adaaaa] font-label text-[10px] uppercase tracking-widest hover:bg-surface-container-high"
              >
                CANCEL
              </button>
              <button
                type="submit"
                class="flex-1 py-2 bg-[#ffa44c] text-black font-label text-[10px] font-bold uppercase tracking-widest"
              >
                DEPLOY
              </button>
            </div>
          </form>
        </div>
        
    <!-- Kanban Board -->
        <div id="kanban-board" phx-hook="KanbanDrag" class="flex gap-6 overflow-x-auto pb-6">
          <div :for={col <- @columns} class="flex-shrink-0 w-80">
            <div class={"flex items-center justify-between mb-4 bg-surface-container-low p-3 border-t-2 #{column_border_color(col)}"}>
              <span class={"font-headline font-bold tracking-widest text-xs uppercase #{column_text_color(col)}"}>
                {humanize_column(col)}
              </span>
              <span class={"font-label text-[10px] px-2 py-0.5 #{column_count_class(col)}"}>
                {length(Map.get(@cards_by_column, col, []))}
              </span>
            </div>
            <div
              class={"space-y-4 min-h-[100px] #{if col == "done", do: "opacity-40"}"}
              id={"column-#{col}"}
              data-column={col}
            >
              <.card_item
                :for={card <- Map.get(@cards_by_column, col, [])}
                card={card}
                columns={@columns}
                current_column={col}
                plan_popup={@plan_popup}
                selected_cards={@selected_cards}
              />
              <div
                :if={Map.get(@cards_by_column, col, []) == []}
                class="text-center py-8 text-[#adaaaa]/30 text-xs font-label uppercase tracking-widest"
              >
                DROP_TARGET
              </div>
            </div>
          </div>
        </div>
        
    <!-- Archived cards -->
        <div
          :if={@show_archived && @archived_cards != []}
          class="bg-surface-container-low p-5 hud-border"
        >
          <.hud_header
            icon="inventory_2"
            label={"ARCHIVED_RECORDS (#{length(@archived_cards)})"}
            class="mb-4"
          />
          <div class="space-y-2">
            <div
              :for={card <- @archived_cards}
              class="flex items-center justify-between p-3 bg-surface-container border border-[#494847]/10"
            >
              <div>
                <div class="font-headline text-sm font-bold text-white uppercase">
                  {Map.get(card, :title, "Untitled")}
                </div>
                <div class="text-[9px] font-label text-[#ffa44c]/40 uppercase">
                  {Map.get(card, :workflow, "—")}
                </div>
              </div>
              <button
                phx-click="restore_card"
                phx-value-id={card.id}
                class="text-[#00eefc] font-label text-[10px] uppercase tracking-widest hover:text-white transition-colors"
              >
                RESTORE
              </button>
            </div>
          </div>
        </div>
      </div>
      
    <!-- Card Detail Modal -->
      <.card_detail_modal
        :if={@detail_card}
        card={@detail_card}
        summary={@detail_summary}
        sessions={@detail_sessions}
        agents={@detail_agents}
        logs={@detail_logs}
        tab={@detail_tab}
        card_history={@card_history}
        detail_plan={@detail_plan}
        workspaces={@workspaces}
      />
    </Layouts.app>
    """
  end

  attr :card, :map, required: true
  attr :columns, :list, required: true
  attr :current_column, :string, required: true
  attr :plan_popup, :map, default: nil
  attr :selected_cards, :any, default: nil

  defp card_item(assigns) do
    metadata = Map.get(assigns.card, :metadata) || %{}

    active_popup? =
      assigns.plan_popup && to_string(assigns.plan_popup.card_id) == to_string(assigns.card.id)

    selected? =
      case assigns[:selected_cards] do
        %MapSet{} = set -> MapSet.member?(set, to_string(assigns.card.id))
        _ -> false
      end

    selectable? = assigns.current_column == "unassigned"

    assigns =
      assigns
      |> assign(:plan_summary, metadata["planSummary"])
      |> assign(:plan_note, metadata["planNote"])
      |> assign(
        :plan_wiki_link,
        metadata["planWikiLink"] ||
          if(metadata["planNote"], do: "[[#{metadata["planNote"]}]]", else: nil)
      )
      |> assign(:active_popup?, active_popup?)
      |> assign(:selected?, selected?)
      |> assign(:selectable?, selectable?)

    ~H"""
    <div
      class={"group relative overflow-visible transition-all #{card_style(@current_column)} #{if @selected?, do: "ring-2 ring-[#00eefc] ring-offset-1 ring-offset-black", else: ""}"}
      data-card-id={@card.id}
    >
      <div :if={@current_column == "in_progress"} class="absolute top-0 right-0 p-1">
        <div class="flex space-x-0.5">
          <div class="w-1 h-1 bg-[#ffa44c]"></div>
          <div class="w-1 h-1 bg-[#ffa44c] animate-pulse"></div>
        </div>
      </div>
      <div class="flex justify-between items-start mb-2">
        <div class="flex items-center gap-2">
          <input
            :if={@selectable?}
            type="checkbox"
            checked={@selected?}
            phx-click="toggle_card_selected"
            phx-value-id={@card.id}
            aria-label={"Select card #{@card.id}"}
            class="w-3.5 h-3.5 accent-[#00eefc] cursor-pointer"
          />
          <span class="font-label text-[9px] text-[#ffa44c]/50">#{Map.get(@card, :id, "")}</span>
        </div>
        <span class="material-symbols-outlined text-[14px] text-[#00eefc]/40 drag-handle cursor-grab active:cursor-grabbing select-none">
          drag_indicator
        </span>
      </div>
      <div
        class="cursor-pointer"
        phx-click="show_card_detail"
        phx-value-id={@card.id}
      >
        <h4 class="font-headline text-sm font-bold text-white mb-3 uppercase leading-tight">
          {Map.get(@card, :title, "Untitled")}
        </h4>
        <div class="flex flex-wrap gap-2 mb-3">
          <span
            :if={Map.get(@card, :workflow)}
            class="text-[8px] font-label px-1.5 py-0.5 bg-[#ffa44c]/10 text-[#ffa44c] border border-[#ffa44c]/20 uppercase"
          >
            {Map.get(@card, :workflow)}
          </span>
          <span
            :if={@plan_summary}
            class="text-[8px] font-label px-1.5 py-0.5 bg-[#00eefc]/10 text-[#00eefc] border border-[#00eefc]/20 uppercase"
          >
            PLAN
          </span>
        </div>

        <div :if={@plan_summary} class="mb-3">
          <p class="text-[10px] text-[#adaaaa] leading-relaxed">{@plan_summary}</p>
        </div>

        <div :if={@plan_note} class="mb-3">
          <span class="text-[#00eefc] font-label text-[9px] uppercase tracking-wider flex items-center gap-1">
            <span class="material-symbols-outlined text-[12px]">article</span> CLICK_TO_VIEW_PLAN
          </span>
        </div>

        <div class="flex justify-between items-center text-[9px] font-label border-t border-[#494847]/20 pt-2">
          <div class="flex flex-col">
            <span class="text-[#00eefc]/40">RUN_ID</span>
            <span class="text-[#00eefc]">
              {if Map.get(@card, :run_id),
                do: String.slice(Map.get(@card, :run_id, ""), 0, 8),
                else: "NONE"}
            </span>
          </div>
          <div class="flex flex-col text-right">
            <span class="text-[#ffa44c]/40">STATUS</span>
            <span class="text-[#ffa44c] uppercase">{@current_column}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Card Detail Modal
  # ---------------------------------------------------------------------------

  attr :card, :map, required: true
  attr :summary, :map, default: nil
  attr :sessions, :list, default: []
  attr :agents, :list, default: []
  attr :logs, :map, default: %{}
  attr :tab, :string, default: "phases"
  attr :card_history, :list, default: []
  attr :detail_plan, :map, default: nil
  attr :workspaces, :list, default: []

  defp card_detail_modal(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-[100] flex items-center justify-center p-8 backdrop-blur-md bg-black/60"
      phx-window-keydown="close_card_detail"
      phx-key="Escape"
    >
      <div
        class="w-full max-w-5xl bg-surface-container-low border border-[#ffa44c]/20 relative flex flex-col max-h-[85vh]"
        phx-click-away="close_card_detail"
      >
        <!-- Modal Header -->
        <div class="flex items-center justify-between p-6 border-b border-[#494847]/10 bg-surface">
          <div class="flex items-center gap-4">
            <div class="w-12 h-12 bg-[#ffa44c]/10 flex items-center justify-center border border-[#ffa44c]/30">
              <span class="material-symbols-outlined text-[#ffa44c] text-3xl">psychology</span>
            </div>
            <div>
              <div class="flex items-center gap-2">
                <span class="text-[#ffa44c] font-label text-xs uppercase tracking-[0.3em]">
                  RECORD_ID: {Map.get(@card, :id, "")}
                </span>
                <span class={"px-2 py-0.5 font-label text-[9px] font-bold #{detail_status_class(Map.get(@card, :column, ""))}"}>
                  {String.upcase(Map.get(@card, :column, "unknown"))}
                </span>
              </div>
              <h2 class="font-headline text-2xl font-bold text-white uppercase tracking-tight">
                {Map.get(@card, :title, "Untitled")}
              </h2>
              <%!-- Workspace badge / selector --%>
              <form phx-change="set_card_workspace" class="flex items-center gap-2 mt-1">
                <span class="material-symbols-outlined text-[#adaaaa]/40 text-sm">folder</span>
                <select
                  name="workspace_id"
                  class="bg-transparent border-none text-[11px] font-label text-[#adaaaa] focus:outline-none cursor-pointer py-0 px-1 -ml-1"
                >
                  <option value="" selected={!@card.workspace_id}>any codebase</option>
                  <option
                    :for={ws <- @workspaces}
                    value={ws.id}
                    selected={ws.id == @card.workspace_id}
                  >
                    {ws.name}{if ws.default_branch && ws.default_branch != "main",
                      do: " (#{ws.default_branch})",
                      else: ""}
                  </option>
                </select>
              </form>
            </div>
          </div>
          <button
            phx-click="close_card_detail"
            class="material-symbols-outlined text-[#ffa44c]/60 hover:text-[#ffa44c] transition-colors"
          >
            close
          </button>
        </div>
        
    <!-- Modal Body -->
        <div class="flex-1 flex overflow-hidden">
          <!-- Tabs Sidebar -->
          <div class="w-48 border-r border-[#494847]/10 bg-black flex flex-col p-4 gap-2">
            <button
              :for={
                {icon, label, tab_id} <- [
                  {"article", "PLAN", "plan"},
                  {"lan", "PHASES", "phases"},
                  {"groups", "AGENTS", "agents"},
                  {"schedule", "SESSIONS", "sessions"},
                  {"description", "LOGS", "logs"},
                  {"history", "HISTORY", "history"}
                ]
              }
              phx-click="detail_tab"
              phx-value-tab={tab_id}
              class={"flex items-center gap-3 px-3 py-3 font-label text-[10px] font-bold tracking-widest uppercase transition-all #{if @tab == tab_id, do: "bg-[#ffa44c] text-black", else: "text-[#ffa44c]/60 hover:bg-[#ffa44c]/10"}"}
            >
              <span class="material-symbols-outlined text-sm">{icon}</span> {label}
            </button>
          </div>
          
    <!-- Content Area -->
          <div class="flex-1 overflow-y-auto p-8 bg-[#0a0a0a]">
            <!-- Summary stats -->
            <div :if={@summary} class="grid grid-cols-4 gap-4 mb-8">
              <div class="bg-surface-container-high p-4 border border-[#00eefc]/10">
                <div class="font-label text-[9px] text-[#00eefc]/60 uppercase mb-1">PHASES</div>
                <div class="font-headline text-2xl font-bold text-[#00eefc]">
                  {@summary.phase_count}
                </div>
              </div>
              <div class="bg-surface-container-high p-4 border border-[#00eefc]/10">
                <div class="font-label text-[9px] text-[#00eefc]/60 uppercase mb-1">AGENTS</div>
                <div class="font-headline text-2xl font-bold text-[#00eefc]">
                  {@summary.agent_count}
                </div>
              </div>
              <div class="bg-surface-container-high p-4 border border-[#ffa44c]/10">
                <div class="font-label text-[9px] text-[#ffa44c]/60 uppercase mb-1">TOKENS</div>
                <div class="font-headline text-2xl font-bold text-[#ffa44c]">
                  {format_large_number(@summary.total_input_tokens + @summary.total_output_tokens)}
                </div>
              </div>
              <div class="bg-surface-container-high p-4 border border-[#ffa44c]/10">
                <div class="font-label text-[9px] text-[#ffa44c]/60 uppercase mb-1">COST</div>
                <div class="font-headline text-2xl font-bold text-[#ffa44c]">
                  {if @summary.total_cost_usd > 0,
                    do: "$#{Float.round(@summary.total_cost_usd, 2)}",
                    else: "—"}
                </div>
              </div>
            </div>

            <.detail_plan
              :if={@tab == "plan"}
              plan={@detail_plan}
              card={@card}
              workspaces={@workspaces}
            />
            <.detail_phases :if={@tab == "phases"} phases={(@summary && @summary.phases) || []} />
            <.detail_agents
              :if={@tab == "agents"}
              agents={@agents}
              agent_details={(@summary && @summary.agent_details) || []}
            />
            <.detail_sessions :if={@tab == "sessions"} sessions={@sessions} />
            <.detail_logs :if={@tab == "logs"} logs={@logs} />
            <div :if={@tab == "history"} class="space-y-3">
              <div
                :if={@card_history == []}
                class="flex flex-col items-center gap-3 py-12 text-[#adaaaa]/40"
              >
                <span class="material-symbols-outlined text-4xl">history</span>
                <p class="font-label text-[10px] uppercase tracking-widest">NO_HISTORY_LOADED</p>
                <button
                  phx-click="load_card_history"
                  phx-value-id={@card.id}
                  class="border border-[#ffa44c]/30 text-[#ffa44c] px-4 py-2 font-label text-[10px] uppercase tracking-widest hover:bg-[#ffa44c]/10 transition-all"
                >
                  LOAD_HISTORY
                </button>
              </div>
              <div :if={@card_history != []} class="space-y-1">
                <div
                  :for={event <- @card_history}
                  class="flex items-center justify-between p-3 bg-surface-container-high border border-[#494847]/10 font-label text-[11px]"
                >
                  <div class="flex items-center gap-3">
                    <span class="text-[#00eefc] uppercase">
                      {event[:event_type] || event["event_type"]}
                    </span>
                    <span class="text-[#adaaaa]/60">
                      {event[:actor] || event["actor"] || "system"}
                    </span>
                  </div>
                  <span class="text-[#ffa44c]/40">
                    {(event[:created_at] || event["created_at"] || "")
                    |> to_string()
                    |> String.slice(0..18)}
                  </span>
                </div>
              </div>
            </div>
          </div>
        </div>
        
    <!-- Modal Footer -->
        <div class="p-4 bg-surface-container-high border-t border-[#494847]/10 flex justify-between items-center px-8">
          <div class="flex gap-4">
            <span class="text-[9px] font-label text-[#ffa44c]/40 uppercase">
              WORKFLOW: {Map.get(@card, :workflow, "—")}
            </span>
            <span class="text-[9px] font-label text-[#ffa44c]/40 uppercase">
              RUN: {Map.get(@card, :run_id, "—") |> to_string() |> String.slice(0, 8)}
            </span>
          </div>
          <div class="flex gap-2">
            <div class="w-2 h-2 bg-[#00eefc]"></div>
            <div class="w-2 h-2 bg-[#00eefc] animate-pulse"></div>
            <div class="w-2 h-2 bg-[#00eefc]"></div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :plan, :map, default: nil
  attr :card, :map, required: true

  attr :workspaces, :list, required: true

  defp detail_plan(assigns) do
    metadata = Map.get(assigns.card, :metadata) || %{}
    idea_plan = metadata["ideaPlan"]

    assigns =
      assigns
      |> assign(:idea_plan, idea_plan)
      |> assign(:plan_summary, metadata["planSummary"])

    ~H"""
    <div :if={!@plan && !@idea_plan} class="flex flex-col items-center py-12 text-[#adaaaa]/40">
      <span class="material-symbols-outlined text-4xl mb-2">article</span>
      <p class="font-label text-[10px] uppercase tracking-widest">NO_PLAN_DATA</p>
    </div>

    <div :if={@idea_plan || @plan}>
      <%!-- IdeaPlan structured view --%>
      <div :if={@idea_plan}>
        <%!-- Source URL --%>
        <div :if={@idea_plan["sourceUrl"] && @idea_plan["sourceUrl"] != ""} class="mb-6">
          <h3 class="text-[#ffa44c] font-label text-[10px] tracking-[0.3em] uppercase mb-2 flex items-center gap-2">
            <span class="w-1 h-3 bg-[#ffa44c]"></span> SOURCE
          </h3>
          <a
            href={@idea_plan["sourceUrl"]}
            target="_blank"
            rel="noopener"
            class="text-[#00eefc] font-label text-xs hover:text-white transition-colors break-all"
          >
            {@idea_plan["sourceUrl"]}
          </a>
        </div>

        <%!-- Summary --%>
        <div :if={@idea_plan["summary"] && @idea_plan["summary"] != ""} class="mb-6">
          <h3 class="text-[#ffa44c] font-label text-[10px] tracking-[0.3em] uppercase mb-2 flex items-center gap-2">
            <span class="w-1 h-3 bg-[#ffa44c]"></span> SUMMARY
          </h3>
          <p class="text-[#adaaaa] text-sm leading-relaxed">{@idea_plan["summary"]}</p>
        </div>

        <%!-- Relevance --%>
        <div :if={@idea_plan["relevance"] && @idea_plan["relevance"] != ""} class="mb-6">
          <h3 class="text-[#ffa44c] font-label text-[10px] tracking-[0.3em] uppercase mb-2 flex items-center gap-2">
            <span class="w-1 h-3 bg-[#00eefc]"></span> RELEVANCE
          </h3>
          <p class="text-[#adaaaa] text-sm leading-relaxed">{@idea_plan["relevance"]}</p>
        </div>

        <%!-- Actionable Steps --%>
        <div :if={@idea_plan["actionableSteps"] && @idea_plan["actionableSteps"] != []} class="mb-6">
          <h3 class="text-[#ffa44c] font-label text-[10px] tracking-[0.3em] uppercase mb-3 flex items-center gap-2">
            <span class="w-1 h-3 bg-[#ffa44c]"></span> IMPLEMENTATION_STEPS
          </h3>
          <div class="space-y-2">
            <div
              :for={{step, idx} <- Enum.with_index(@idea_plan["actionableSteps"], 1)}
              class="flex gap-3 p-3 bg-surface-container-high border border-[#494847]/20"
            >
              <span class="text-[#ffa44c] font-headline text-lg font-bold shrink-0 w-6 text-right">
                {idx}
              </span>
              <p class="text-[#adaaaa] text-xs leading-relaxed">{step}</p>
            </div>
          </div>
        </div>

        <%!-- Affected Files --%>
        <div :if={@idea_plan["affectedFiles"] && @idea_plan["affectedFiles"] != []} class="mb-6">
          <h3 class="text-[#ffa44c] font-label text-[10px] tracking-[0.3em] uppercase mb-3 flex items-center gap-2">
            <span class="w-1 h-3 bg-[#00eefc]"></span> AFFECTED_FILES
          </h3>
          <div class="grid grid-cols-2 gap-1">
            <div
              :for={file <- @idea_plan["affectedFiles"]}
              class="px-3 py-2 bg-surface-container-high border border-[#494847]/10 font-label text-[11px] text-[#00eefc] truncate"
              title={file}
            >
              {file}
            </div>
          </div>
        </div>

        <%!-- Metadata badges --%>
        <div class="flex flex-wrap gap-4 pt-4 border-t border-[#494847]/20">
          <div
            :if={@idea_plan["effortEstimate"]}
            class="bg-surface-container-high px-3 py-2 border border-[#ffa44c]/10"
          >
            <div class="font-label text-[9px] text-[#ffa44c]/60 uppercase">EFFORT</div>
            <div class="font-headline text-sm font-bold text-[#ffa44c]">
              {@idea_plan["effortEstimate"]}
            </div>
          </div>
          <div
            :if={@idea_plan["complexity"]}
            class="bg-surface-container-high px-3 py-2 border border-[#00eefc]/10"
          >
            <div class="font-label text-[9px] text-[#00eefc]/60 uppercase">COMPLEXITY</div>
            <div class="font-headline text-sm font-bold text-[#00eefc]">
              {@idea_plan["complexity"]}
            </div>
          </div>
          <div
            :if={@idea_plan["suggestedWorkflow"]}
            class="bg-surface-container-high px-3 py-2 border border-[#ffa44c]/10"
          >
            <div class="font-label text-[9px] text-[#ffa44c]/60 uppercase">WORKFLOW</div>
            <div class="font-headline text-sm font-bold text-[#ffa44c]">
              {@idea_plan["suggestedWorkflow"]}
            </div>
          </div>
        </div>
      </div>

      <%!-- Vault note raw content (fallback when no ideaPlan) --%>
      <div :if={!@idea_plan && @plan}>
        <h3 class="text-[#ffa44c] font-label text-[10px] tracking-[0.3em] uppercase mb-3 flex items-center gap-2">
          <span class="w-1 h-3 bg-[#ffa44c]"></span> {@plan.title}
        </h3>
        <div class="font-label text-[9px] text-[#ffa44c]/40 mb-4">{@plan.path}</div>
        <pre class="whitespace-pre-wrap break-words font-label text-[11px] leading-6 text-[#adaaaa]">{@plan.content}</pre>
      </div>

      <%!-- Workspace target indicator --%>
      <div :if={@card.workspace_id} class="mt-8 pt-6 border-t border-[#494847]/30">
        <span class="font-label text-[9px] text-[#adaaaa]/40">
          Target: {Enum.find(@workspaces, &(&1.id == @card.workspace_id))
          |> then(&((&1 && &1.repo_path) || "unknown"))}
        </span>
      </div>
    </div>
    """
  end

  attr :phases, :list, required: true

  defp detail_phases(assigns) do
    ~H"""
    <div :if={@phases == []} class="flex flex-col items-center py-12 text-[#adaaaa]/40">
      <span class="material-symbols-outlined text-4xl mb-2">lan</span>
      <p class="font-label text-[10px] uppercase tracking-widest">NO_PHASE_DATA</p>
    </div>
    <div :if={@phases != []}>
      <h3 class="text-[#ffa44c] font-label text-[10px] tracking-[0.3em] uppercase mb-4 flex items-center gap-2">
        <span class="w-1 h-3 bg-[#ffa44c]"></span> EXECUTION_TIMELINE
      </h3>
      <div class="relative pl-6 space-y-6 border-l border-[#ffa44c]/20">
        <div
          :for={{phase, _idx} <- Enum.with_index(@phases)}
          class={"relative #{if phase.status != "done" && phase.status != "running", do: "opacity-60"}"}
        >
          <div class={"absolute -left-[29px] top-1 w-2 h-2 #{phase_dot_class(phase.status)}"}></div>
          <div class="text-[10px] font-bold text-[#ffa44c] mb-1 uppercase tracking-tighter">
            {phase.name}
          </div>
          <div class="flex items-center gap-3 text-[10px] text-[#adaaaa]">
            <span :if={phase.started_at}>START: {String.slice(phase.started_at || "", 11, 8)}</span>
            <span :if={phase.ended_at}>END: {String.slice(phase.ended_at || "", 11, 8)}</span>
            <span :if={phase.agents != []} class="text-[#00eefc]">
              {length(phase.agents)} AGENT{if length(phase.agents) != 1, do: "S"}
            </span>
            <span :if={phase.phase_type} class="text-[#ffa44c]/40">{phase.phase_type}</span>
          </div>
          <span class={"inline-block mt-1 px-2 py-0.5 font-label text-[8px] uppercase #{phase_nerv_badge(phase.status)}"}>
            {phase.status}
          </span>
        </div>
      </div>
    </div>
    """
  end

  attr :agents, :list, required: true
  attr :agent_details, :list, required: true

  defp detail_agents(assigns) do
    ~H"""
    <div
      :if={@agents == [] and @agent_details == []}
      class="flex flex-col items-center py-12 text-[#adaaaa]/40"
    >
      <span class="material-symbols-outlined text-4xl mb-2">groups</span>
      <p class="font-label text-[10px] uppercase tracking-widest">NO_AGENT_DATA</p>
    </div>
    <div :if={@agents != [] or @agent_details != []} class="space-y-3">
      <h3 class="text-[#00eefc] font-label text-[10px] tracking-[0.3em] uppercase mb-4 flex items-center gap-2">
        <span class="w-1 h-3 bg-[#00eefc]"></span> AGENT_REGISTRY
      </h3>
      <div
        :for={agent <- if(@agents != [], do: @agents, else: @agent_details)}
        class="bg-surface-container-high p-4 border border-[#00eefc]/10"
      >
        <div class="flex items-center gap-2 mb-2">
          <span class="material-symbols-outlined text-[#00eefc] text-sm">smart_toy</span>
          <span class="font-headline text-sm font-bold text-white uppercase">
            {agent_name(agent)}
          </span>
          <span
            :if={Map.get(agent, :phase_name)}
            class="text-[8px] font-label px-1.5 py-0.5 bg-[#ffa44c]/10 text-[#ffa44c] border border-[#ffa44c]/20 uppercase"
          >
            {Map.get(agent, :phase_name)}
          </span>
        </div>
        <div :if={Map.get(agent, :events) && Map.get(agent, :events) != []} class="ml-6 space-y-1">
          <div
            :for={ev <- Map.get(agent, :events, [])}
            class="text-[10px] font-label text-[#adaaaa]/60 flex gap-3"
          >
            <span class="text-[#00eefc]/40 shrink-0">{String.slice(ev.timestamp || "", 11, 8)}</span>
            <span class={event_color(ev.event)}>{ev.event}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :sessions, :list, required: true

  defp detail_sessions(assigns) do
    ~H"""
    <div :if={@sessions == []} class="flex flex-col items-center py-12 text-[#adaaaa]/40">
      <span class="material-symbols-outlined text-4xl mb-2">schedule</span>
      <p class="font-label text-[10px] uppercase tracking-widest">NO_SESSION_DATA</p>
    </div>
    <div :if={@sessions != []}>
      <h3 class="text-[#00eefc] font-label text-[10px] tracking-[0.3em] uppercase mb-4 flex items-center gap-2">
        <span class="w-1 h-3 bg-[#00eefc]"></span> SESSION_TELEMETRY
      </h3>
      <div class="bg-surface-container-high border border-[#494847]/10 overflow-x-auto">
        <table class="w-full text-left border-collapse">
          <thead>
            <tr class="border-b border-[#494847]/20 bg-surface-container-high/50">
              <th class="px-4 py-3 font-label text-[10px] tracking-widest text-[#00eefc]">SESSION</th>
              <th class="px-4 py-3 font-label text-[10px] tracking-widest text-[#00eefc]">TYPE</th>
              <th class="px-4 py-3 font-label text-[10px] tracking-widest text-[#00eefc] text-right">
                INPUT
              </th>
              <th class="px-4 py-3 font-label text-[10px] tracking-widest text-[#00eefc] text-right">
                OUTPUT
              </th>
              <th class="px-4 py-3 font-label text-[10px] tracking-widest text-[#00eefc] text-right">
                TOOLS
              </th>
              <th class="px-4 py-3 font-label text-[10px] tracking-widest text-[#00eefc] text-right">
                COST
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-[#494847]/10 font-label text-xs">
            <tr :for={s <- @sessions} class="hover:bg-surface-container transition-colors">
              <td class="px-4 py-3 font-bold text-white">{s.short_id}</td>
              <td class="px-4 py-3">
                <span :if={Map.get(s, :execution_type) == "api"} class="text-[#ffa44c]">API</span>
                <span
                  :if={Map.get(s, :execution_type) in ["subscription", "sdk"]}
                  class="text-[#00eefc]"
                >
                  MAX
                </span>
                <span
                  :if={Map.get(s, :execution_type) not in ["api", "subscription", "sdk"]}
                  class="text-[#777575]"
                >
                  —
                </span>
              </td>
              <td class="px-4 py-3 text-right text-[#adaaaa]">
                {format_large_number(s.total_input_tokens)}
              </td>
              <td class="px-4 py-3 text-right text-[#adaaaa]">
                {format_large_number(s.total_output_tokens)}
              </td>
              <td class="px-4 py-3 text-right text-[#adaaaa]">{s.tool_count}</td>
              <td class="px-4 py-3 text-right text-[#ffa44c]">
                {if Map.get(s, :execution_type) in ["subscription", "sdk"],
                  do: "—",
                  else: "$#{Float.round(s.total_cost_usd, 2)}"}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <div class="flex justify-end gap-6 mt-3 text-[10px] font-label text-[#adaaaa]/60 uppercase">
        <span>
          TOTAL_TOKENS:
          <b class="text-[#00eefc]">
            {format_large_number(
              Enum.reduce(@sessions, 0, &(&1.total_input_tokens + &1.total_output_tokens + &2))
            )}
          </b>
        </span>
        <span>
          API_COST:
          <b class="text-[#ffa44c]">
            ${Float.round(
              Enum.reduce(@sessions, 0.0, fn s, acc ->
                if Map.get(s, :execution_type) == "api", do: acc + s.total_cost_usd, else: acc
              end),
              2
            )}
          </b>
        </span>
      </div>
    </div>
    """
  end

  attr :logs, :map, required: true

  defp detail_logs(assigns) do
    sorted_logs = assigns.logs |> Enum.sort_by(fn {k, _} -> k end) |> Enum.to_list()
    assigns = assign(assigns, sorted_logs: sorted_logs)

    ~H"""
    <div :if={@sorted_logs == []} class="flex flex-col items-center py-12 text-[#adaaaa]/40">
      <span class="material-symbols-outlined text-4xl mb-2">description</span>
      <p class="font-label text-[10px] uppercase tracking-widest">NO_SESSION_LOGS</p>
      <p class="font-label text-[9px] text-[#adaaaa]/30 mt-1">
        SDK RUNS DO NOT PRODUCE SESSION LOG FILES
      </p>
    </div>
    <div :if={@sorted_logs != []} class="space-y-4">
      <h3 class="text-[#00eefc] font-label text-[10px] tracking-[0.3em] uppercase mb-4 flex items-center gap-2">
        <span class="w-1 h-3 bg-[#00eefc]"></span> TERMINAL_OUTPUT
      </h3>
      <div
        :for={{phase_id, content} <- @sorted_logs}
        class="bg-surface-container-high border border-[#494847]/10"
      >
        <div class="px-4 py-2 border-b border-[#494847]/10 flex items-center gap-2">
          <span class="material-symbols-outlined text-[#00eefc] text-sm">terminal</span>
          <span class="font-label text-[10px] text-white uppercase tracking-widest">{phase_id}</span>
        </div>
        <pre class="p-4 text-[11px] font-label text-[#00FF41] overflow-x-auto max-h-60 whitespace-pre-wrap">{String.slice(content || "", -5000, 5000)}</pre>
      </div>
    </div>
    """
  end

  # Column styling helpers
  defp column_border_color("ideation"), do: "border-[#ffa44c]/40"
  defp column_border_color("unassigned"), do: "border-[#494847]/40"
  defp column_border_color("todo"), do: "border-[#00eefc]/40"
  defp column_border_color("in_progress"), do: "border-[#ffa44c]"
  defp column_border_color("review"), do: "border-[#00eefc]"
  defp column_border_color("done"), do: "border-[#ea8400]/40"
  defp column_border_color(_), do: "border-[#494847]/40"

  defp column_text_color("ideation"), do: "text-[#ffa44c]"
  defp column_text_color("unassigned"), do: "text-[#adaaaa]"
  defp column_text_color("todo"), do: "text-[#00eefc]"
  defp column_text_color("in_progress"), do: "text-[#ffa44c]"
  defp column_text_color("review"), do: "text-[#00eefc]"
  defp column_text_color("done"), do: "text-[#ffa44c]/40"
  defp column_text_color(_), do: "text-[#adaaaa]"

  defp column_count_class("in_progress"), do: "bg-[#ffa44c] text-black"
  defp column_count_class("review"), do: "bg-[#00eefc] text-black"
  defp column_count_class("todo"), do: "bg-[#00eefc]/20 text-[#00eefc]"
  defp column_count_class("ideation"), do: "bg-[#ffa44c]/20 text-[#ffa44c]"
  defp column_count_class("done"), do: "bg-[#ffa44c]/10 text-[#ffa44c]/40"
  defp column_count_class(_), do: "bg-[#262626] text-[#adaaaa]"

  defp card_style("in_progress"), do: "bg-[#ffa44c]/5 border border-[#ffa44c] p-4 relative"

  defp card_style("review"),
    do:
      "bg-surface-container-high p-4 border-l-4 border-[#00eefc]/50 hover:border-[#00eefc] transition-all"

  defp card_style("todo"),
    do:
      "bg-surface-container-high p-4 border-r-4 border-[#00eefc]/10 hover:border-[#00eefc] transition-all"

  defp card_style("done"), do: "bg-surface-container-low p-4 border border-[#494847]/10"

  defp card_style("ideation"),
    do:
      "bg-surface-container-high border-l-2 border-[#ffa44c]/20 p-4 hover:border-[#00eefc]/60 transition-all"

  defp card_style(_), do: "bg-surface-container-high p-4 border border-[#494847]/10"

  defp detail_status_class("in_progress"), do: "bg-[#ffa44c] text-black"
  defp detail_status_class("done"), do: "bg-[#00FF41]/20 text-[#00FF41]"
  defp detail_status_class("review"), do: "bg-[#00eefc]/20 text-[#00eefc]"
  defp detail_status_class("failed"), do: "bg-[#ff725e]/20 text-[#ff725e]"
  defp detail_status_class(_), do: "bg-[#ffa44c]/20 text-[#ffa44c]"

  # Phase helpers
  defp phase_dot_class("done"), do: "bg-[#00FF41]"
  defp phase_dot_class("running"), do: "bg-[#ffa44c] animate-pulse"
  defp phase_dot_class("failed"), do: "bg-[#ff725e]"
  defp phase_dot_class(_), do: "border border-[#ffa44c] bg-surface"

  defp phase_nerv_badge("done"), do: "bg-[#00FF41]/10 text-[#00FF41] border border-[#00FF41]/30"

  defp phase_nerv_badge("running"),
    do: "bg-[#00eefc]/10 text-[#00eefc] border border-[#00eefc]/30"

  defp phase_nerv_badge("failed"), do: "bg-[#ff725e]/10 text-[#ff725e] border border-[#ff725e]/30"
  defp phase_nerv_badge(_), do: "bg-[#ffa44c]/10 text-[#ffa44c] border border-[#ffa44c]/30"

  defp agent_name(%{name: name}) when is_binary(name), do: name
  defp agent_name(%{agent_name: name}) when is_binary(name), do: name
  defp agent_name(_), do: "Unknown Agent"

  defp event_color("spawned"), do: "text-[#00eefc]"
  defp event_color("completed"), do: "text-[#00FF41]"
  defp event_color("failed"), do: "text-[#ff725e]"
  defp event_color(_), do: ""

  defp format_large_number(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  defp format_large_number(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}K"

  defp format_large_number(n) when is_number(n), do: to_string(n)
  defp format_large_number(_), do: "0"

  defp all_cards(socket) do
    by_col = socket.assigns[:cards_by_column] || %{}
    archived = socket.assigns[:archived_cards] || []
    Enum.flat_map(by_col, fn {_col, cards} -> cards end) ++ archived
  end

  defp load_card_detail(card) do
    run_id = Map.get(card, :run_id)

    if run_id && run_id != "" do
      summary = safe_call(fn -> TraceReader.run_summary(run_id) end, nil)

      sessions =
        safe_call(fn -> CostEventReader.sessions_for_run(run_id) end, [])

      agents = safe_call(fn -> TraceReader.lifecycle_agents(run_id) end, [])
      logs = safe_call(fn -> TraceReader.session_logs_for_run(run_id) end, %{})
      {summary, sessions, agents, logs}
    else
      {nil, [], [], %{}}
    end
  rescue
    _ -> {nil, [], [], %{}}
  end

  defp humanize_column("in_progress"), do: "In Progress"
  defp humanize_column("unassigned"), do: "Unassigned"
  defp humanize_column("todo"), do: "To Do"
  defp humanize_column(col), do: String.capitalize(col)
end
