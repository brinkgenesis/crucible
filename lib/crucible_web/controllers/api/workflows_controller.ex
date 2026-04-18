defmodule CrucibleWeb.Api.WorkflowsController do
  use CrucibleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Crucible.WorkflowStore

  operation(:index,
    summary: "List workflows",
    description: "Returns all workflow definitions from the workflow store.",
    tags: ["Workflows"],
    responses: [ok: {"Workflow list", "application/json", %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}}}]
  )
  def index(conn, _params) do
    workflows = safe_call(fn -> WorkflowStore.list() end, [])
    json(conn, workflows)
  end

  operation(:show,
    summary: "Get workflow",
    description: "Returns a single workflow definition by name.",
    tags: ["Workflows"],
    parameters: [
      name: [in: :path, type: :string, required: true, description: "Workflow name"]
    ],
    responses: [
      ok: {"Workflow definition", "application/json", %OpenApiSpex.Schema{type: :object}},
      not_found: {"Not found", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )
  def show(conn, %{"name" => name}) do
    case safe_call(fn -> WorkflowStore.get(name) end, nil) do
      nil ->
        error_json(conn, 404, "not_found", "Resource not found")

      {:ok, workflow} ->
        json(conn, workflow)

      {:error, :not_found} ->
        error_json(conn, 404, "not_found", "Resource not found")
    end
  end
end
