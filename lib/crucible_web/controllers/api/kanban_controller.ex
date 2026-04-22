defmodule CrucibleWeb.Api.KanbanController do
  use CrucibleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Crucible.{Orchestrator, Repo, WorkflowStore}

  alias CrucibleWeb.Schemas.Common.{
    KanbanCard,
    CreateCardRequest,
    ErrorResponse,
    OkResponse
  }

  import Ecto.Query
  require Logger

  tags(["Kanban"])
  security([%{"cookieAuth" => []}])

  operation(:index,
    summary: "List kanban cards",
    parameters: [
      archived: [
        in: :query,
        type: :boolean,
        required: false,
        description: "Include archived cards (default false)"
      ]
    ],
    responses: [
      ok: {"Card list", "application/json", %OpenApiSpex.Schema{type: :array, items: KanbanCard}}
    ]
  )

  def index(conn, params) do
    adapter = kanban_adapter()

    case adapter.list_cards() do
      {:ok, cards} ->
        archived? = Map.get(params, "archived", "false") == "true"
        filtered = Enum.filter(cards, &(Map.get(&1, :archived, false) == archived?))
        json(conn, Enum.map(filtered, &serialize_card/1))

      {:error, reason} ->
        Logger.error("KanbanController: operation failed: #{inspect(reason)}")
        error_json(conn, 500, "internal_error", "An internal error occurred")
    end
  end

  operation(:show,
    summary: "Get a kanban card",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Card detail", "application/json", KanbanCard},
      not_found: {"Not found", "application/json", ErrorResponse}
    ]
  )

  def show(conn, %{"id" => id}) do
    adapter = kanban_adapter()

    case adapter.get_card(id) do
      {:ok, card} ->
        json(conn, serialize_card(card))

      {:error, :not_found} ->
        error_json(conn, 404, "not_found", "Resource not found")

      {:error, reason} ->
        Logger.error("KanbanController: operation failed: #{inspect(reason)}")
        error_json(conn, 500, "internal_error", "An internal error occurred")
    end
  end

  operation(:create,
    summary: "Create a kanban card",
    request_body: {"Card attributes", "application/json", CreateCardRequest},
    responses: [
      created: {"Created card", "application/json", KanbanCard},
      unprocessable_entity: {"Validation error", "application/json", ErrorResponse}
    ]
  )

  def create(conn, params) do
    adapter = kanban_adapter()

    attrs = %{
      id: Map.get(params, "id", Ecto.UUID.generate()),
      title: Map.get(params, "title", "Untitled"),
      column: Map.get(params, "column", "unassigned"),
      workflow: Map.get(params, "workflow"),
      metadata: Map.get(params, "metadata", %{})
    }

    case adapter.create_card(attrs) do
      {:ok, card} ->
        conn |> put_status(201) |> json(serialize_card(card))

      {:error, reason} ->
        Logger.warning("KanbanController: validation failed: #{inspect(reason)}")
        error_json(conn, 422, "unprocessable_entity", "Request could not be processed")
    end
  end

  operation(:update,
    summary: "Update a kanban card",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body:
      {"Update fields", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           title: %OpenApiSpex.Schema{type: :string},
           workflow: %OpenApiSpex.Schema{type: :string},
           metadata: %OpenApiSpex.Schema{type: :object}
         }
       }},
    responses: [
      ok: {"Updated card", "application/json", KanbanCard},
      not_found: {"Not found", "application/json", ErrorResponse}
    ]
  )

  def update(conn, %{"id" => id} = params) do
    adapter = kanban_adapter()

    updates =
      params
      |> Map.take(~w(title workflow metadata))
      |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
      |> Map.new()

    case adapter.update_card(id, updates) do
      {:ok, card} ->
        json(conn, serialize_card(card))

      {:error, :not_found} ->
        error_json(conn, 404, "not_found", "Resource not found")

      {:error, reason} ->
        Logger.warning("KanbanController: validation failed: #{inspect(reason)}")
        error_json(conn, 422, "unprocessable_entity", "Request could not be processed")
    end
  end

  operation(:delete,
    summary: "Delete a kanban card",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Deleted", "application/json", OkResponse},
      not_found: {"Not found", "application/json", ErrorResponse}
    ]
  )

  def delete(conn, %{"id" => id}) do
    adapter = kanban_adapter()

    case adapter.delete_card(id) do
      :ok ->
        json(conn, %{ok: true})

      {:error, :not_found} ->
        error_json(conn, 404, "not_found", "Resource not found")

      {:error, reason} ->
        Logger.error("KanbanController: operation failed: #{inspect(reason)}")
        error_json(conn, 500, "internal_error", "An internal error occurred")
    end
  end

  def move(conn, %{"id" => id, "column" => column}) do
    adapter = kanban_adapter()

    case adapter.move_card(id, column) do
      {:ok, card} ->
        if column == "todo", do: maybe_trigger_workflow(card, adapter)
        json(conn, serialize_card(card))

      {:error, :not_found} ->
        error_json(conn, 404, "not_found", "Resource not found")

      {:error, reason} ->
        Logger.warning("KanbanController: validation failed: #{inspect(reason)}")
        error_json(conn, 422, "unprocessable_entity", "Request could not be processed")
    end
  end

  def move(conn, %{"id" => _id}) do
    error_json(conn, 400, "bad_request", "Missing required column parameter")
  end

  def archive(conn, %{"id" => id}) do
    adapter = kanban_adapter()

    case adapter.archive_card(id) do
      {:ok, card} ->
        json(conn, serialize_card(card))

      {:error, :not_found} ->
        error_json(conn, 404, "not_found", "Resource not found")

      {:error, reason} ->
        Logger.error("KanbanController: operation failed: #{inspect(reason)}")
        error_json(conn, 500, "internal_error", "An internal error occurred")
    end
  end

  def restore(conn, %{"id" => id}) do
    adapter = kanban_adapter()

    case adapter.restore_card(id) do
      {:ok, card} ->
        json(conn, serialize_card(card))

      {:error, :not_found} ->
        error_json(conn, 404, "not_found", "Resource not found")

      {:error, reason} ->
        Logger.error("KanbanController: operation failed: #{inspect(reason)}")
        error_json(conn, 500, "internal_error", "An internal error occurred")
    end
  end

  def history(conn, %{"id" => id}) do
    alias Crucible.Schema.CardEvent

    events =
      from(e in CardEvent,
        where: e.card_id == ^id,
        order_by: [desc: e.occurred_at],
        limit: 100
      )
      |> Repo.all()
      |> Enum.map(fn e ->
        %{
          id: e.id,
          eventType: e.event_type,
          occurredAt: format_dt(e.occurred_at),
          actor: e.actor,
          payload: e.payload
        }
      end)

    json(conn, events)
  end

  def plan(conn, %{"id" => id} = params) do
    adapter = kanban_adapter()
    workflow_name = Map.get(params, "workflow", "coding-sprint")
    execution_type = normalize_execution_type(Map.get(params, "executionType"))

    case adapter.get_card(id) do
      {:ok, card} ->
        trigger_workflow(card, adapter, execution_type)
        json(conn, %{ok: true, cardId: id, workflow: workflow_name})

      {:error, :not_found} ->
        error_json(conn, 404, "not_found", "Resource not found")
    end
  end

  defp kanban_adapter do
    Application.get_env(:crucible, :kanban_adapter, Crucible.Kanban.DbAdapter)
  end

  defp serialize_card(card) do
    %{
      id: Map.get(card, :id),
      title: Map.get(card, :title),
      column: Map.get(card, :column),
      archived: Map.get(card, :archived, false),
      workflow: Map.get(card, :workflow),
      metadata: Map.get(card, :metadata, %{}),
      createdAt: Map.get(card, :created_at) |> format_dt(),
      updatedAt: Map.get(card, :updated_at) |> format_dt()
    }
  end

  defp format_dt(nil), do: nil
  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_dt(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp format_dt(other), do: to_string(other)

  defp maybe_trigger_workflow(card, adapter) do
    has_parent = Map.get(card, :parent_card_id)
    run_id = Map.get(card, :run_id)
    run_active = run_id && run_active?(run_id)

    cond do
      has_parent -> :skip
      run_active -> :skip
      true -> trigger_workflow(card, adapter)
    end
  end

  defp run_active?(run_id) do
    case Orchestrator.lookup_run(run_id) do
      {:ok, _pid, _meta} -> true
      :not_found -> false
    end
  end

  defp trigger_workflow(card, adapter, execution_type \\ "subscription") do
    workflow_name = Map.get(card, :workflow) || "coding-sprint"

    case WorkflowStore.get(workflow_name) do
      {:ok, workflow_config} ->
        run_id = :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)

        # Ensure plan exists — generate one if missing
        {metadata, plan_note, plan_summary} = ensure_plan(card, adapter)

        complexity =
          get_in(metadata, ["complexity"]) || get_in(metadata, ["ideaPlan", "complexity"])

        manifest =
          workflow_config
          |> Map.put("run_id", run_id)
          |> Map.put("workflow_name", workflow_name)
          |> Map.put("status", "pending")
          |> Map.put("execution_type", execution_type)
          |> Map.put("card_id", card.id)
          |> Map.put("plan_note", plan_note)
          |> Map.put("plan_summary", plan_summary)
          |> Map.put("complexity", complexity)
          |> Map.put("task_description", Map.get(card, :title))
          |> Map.put("created_at", DateTime.utc_now() |> DateTime.to_iso8601())

        case Orchestrator.submit_run(manifest) do
          :ok ->
            adapter.update_card(card.id, %{run_id: run_id})

            adapter.log_card_event(card.id, "card_planned", %{
              workflow: workflow_name,
              run_id: run_id
            })

            Logger.info(
              "KanbanController: triggered #{workflow_name} for card #{card.id} (run #{run_id})"
            )

          {:error, reason} ->
            Logger.error("KanbanController: failed to trigger workflow: #{inspect(reason)}")
        end

      {:error, :not_found} ->
        Logger.error("KanbanController: workflow '#{workflow_name}' not found")
    end
  end

  # Returns {metadata, plan_note, plan_summary} from existing card metadata.
  # If no plan is present the run still proceeds — the agent receives the
  # card title as its task description and discovers context as it works.
  defp ensure_plan(card, _adapter) do
    metadata = Map.get(card, :metadata) || %{}
    plan_note = get_in(metadata, ["planNote"])
    plan_summary = get_in(metadata, ["planSummary"])

    unless plan_note && plan_summary do
      Logger.info(
        "KanbanController: card #{card.id} has no stored plan — running with title only"
      )
    end

    {metadata, plan_note, plan_summary}
  end

  defp normalize_execution_type("api"), do: "api"
  defp normalize_execution_type(_), do: "subscription"
end
