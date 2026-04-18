defmodule CrucibleWeb.Api.WebhookController do
  use CrucibleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Crucible.Orchestrator
  alias Crucible.Validation.Manifest
  require Logger

  tags(["Webhooks"])
  security([%{"cookieAuth" => []}])

  operation(:trigger,
    summary: "Trigger a workflow run",
    description:
      "Validates and submits a workflow run manifest. Returns 202 on acceptance, 422 on validation failure.",
    responses: [
      accepted: {"Run accepted", "application/json", %OpenApiSpex.Schema{type: :object}},
      unprocessable_entity:
        {"Validation failed", "application/json", %OpenApiSpex.Schema{type: :object}},
      internal_server_error:
        {"Internal error", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def trigger(conn, params) do
    with {:ok, run_manifest} <- Manifest.validate(params) do
      case safe_call(fn -> Orchestrator.submit_run(run_manifest) end, {:error, :internal}) do
        :ok ->
          conn
          |> put_status(202)
          |> json(%{status: "accepted", runId: run_manifest["run_id"]})

        {:error, {:workflow_resolution_failed, message}} ->
          Logger.warning("WebhookController: workflow resolution failed: #{message}")
          error_json(conn, 422, "workflow_resolution_failed", message)

        {:error, {:validation_failed, errors}} when is_list(errors) ->
          error_json(conn, 422, "validation_failed", "Manifest validation failed",
            Enum.map(errors, fn {field, msg} -> %{field: field, message: msg} end)
          )

        {:error, reason} ->
          Logger.error("WebhookController: submit_run failed: #{inspect(reason)}")
          error_json(conn, 500, "internal_error", "An internal error occurred")
      end
    else
      {:error, errors} when is_list(errors) ->
        conn
        |> put_status(422)
        |> json(%{
          error: "validation_failed",
          details: Enum.map(errors, fn {field, msg} -> %{field: field, message: msg} end)
        })
    end
  end
end
