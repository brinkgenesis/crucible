defmodule CrucibleWeb.Api.RunsController do
  use CrucibleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Crucible.{CostEventReader, TraceReader}
  alias CrucibleWeb.Api.ErrorCodes
  alias CrucibleWeb.Schemas.Common.{ErrorResponse, RunDetail, RunSummary}

  tags(["Runs"])
  security([%{"cookieAuth" => []}])

  @max_limit 100
  @default_limit 20

  operation(:index,
    summary: "List all runs",
    description: "Returns workflow runs with summary information.",
    parameters: [
      limit: [
        in: :query,
        type: :integer,
        required: false,
        description: "Max results (1-100, default 20)"
      ],
      offset: [
        in: :query,
        type: :integer,
        required: false,
        description: "Number of results to skip (default 0)"
      ],
      client_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Filter by client ID"
      ],
      workspace: [
        in: :query,
        type: :string,
        required: false,
        description: "Filter by workspace path"
      ]
    ],
    responses: [
      ok: {"Run list", "application/json", %OpenApiSpex.Schema{type: :array, items: RunSummary}}
    ]
  )

  def index(conn, params) do
    client_id = blank_to_nil(Map.get(params, "client_id") || Map.get(params, "clientId"))
    workspace = blank_to_nil(Map.get(params, "workspace"))

    with {:ok, limit, offset} <- parse_pagination(params) do
      runs =
        safe_call(fn -> TraceReader.list_runs(client_id: client_id, workspace: workspace) end, [])

      serialized = Enum.map(runs, &serialize_trace_run/1)
      total = length(serialized)
      paginated = serialized |> Enum.drop(offset) |> Enum.take(limit)

      meta = %{total: total, limit: limit, offset: offset, hasMore: offset + limit < total}
      json(conn, %{data: paginated, pagination: meta})
    else
      {:error, field, msg} ->
        conn
        |> put_status(400)
        |> json(%{error: ErrorCodes.invalid_params(%{field => msg})})
    end
  end

  operation(:show,
    summary: "Get run details",
    description: "Returns detailed information about a specific run including phases.",
    parameters: [id: [in: :path, type: :string, required: true, description: "Run ID"]],
    responses: [
      ok: {"Run detail", "application/json", RunDetail},
      not_found: {"Run not found", "application/json", ErrorResponse}
    ]
  )

  def show(conn, %{"id" => run_id}) do
    manifest = safe_call(fn -> TraceReader.run_manifest(run_id) end, nil)
    summary = safe_call(fn -> TraceReader.run_summary(run_id) end, nil)

    known_run? =
      safe_call(
        fn ->
          TraceReader.list_runs()
          |> Enum.any?(&(&1.run_id == run_id))
        end,
        false
      )

    has_summary_events? =
      is_map(summary) and Map.get(summary, :event_count, 0) > 0

    case {manifest, has_summary_events?, known_run?} do
      {nil, false, false} ->
        conn
        |> put_status(404)
        |> json(%{error: ErrorCodes.not_found()})

      _ ->
        json(conn, serialize_run_detail(run_id, manifest, summary))
    end
  end

  operation(:sessions,
    summary: "Get run sessions",
    description: "Returns cost-tracking sessions, optionally filtered by run and scope.",
    parameters: [
      runId: [in: :query, type: :string, required: false, description: "Filter by run ID prefix"],
      client_id: [in: :query, type: :string, required: false, description: "Filter by client ID"],
      workspace: [
        in: :query,
        type: :string,
        required: false,
        description: "Filter by workspace path"
      ]
    ],
    responses: [
      ok:
        {"Sessions list", "application/json",
         %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}}}
    ]
  )

  def sessions(conn, params) do
    run_id = blank_to_nil(Map.get(params, "runId"))
    client_id = blank_to_nil(Map.get(params, "client_id") || Map.get(params, "clientId"))
    workspace = blank_to_nil(Map.get(params, "workspace"))

    sessions =
      cond do
        run_id && client_id == nil && workspace == nil ->
          safe_call(fn -> CostEventReader.sessions_for_run(run_id) end, [])

        run_id ->
          safe_call(
            fn -> CostEventReader.all_sessions(client_id: client_id, workspace: workspace) end,
            []
          )
          |> Enum.filter(fn session ->
            session_run_id = Map.get(session, :run_id) || ""
            short_id = Map.get(session, :short_id) || ""
            String.starts_with?(session_run_id, run_id) or String.starts_with?(short_id, run_id)
          end)

        true ->
          safe_call(
            fn -> CostEventReader.all_sessions(client_id: client_id, workspace: workspace) end,
            []
          )
      end

    json(conn, sessions)
  end

  operation(:loops,
    summary: "Get loop detections for a run",
    parameters: [id: [in: :path, type: :string, required: true, description: "Run ID"]],
    responses: [ok: {"Loop events", "application/json", %OpenApiSpex.Schema{type: :object}}]
  )

  def loops(conn, %{"id" => run_id}) do
    events = safe_call(fn -> TraceReader.events_for_run(run_id) end, [])

    loop_events =
      events
      |> Enum.filter(fn event -> Map.get(event, "eventType") == "loop_detected" end)

    json(conn, %{loops: loop_events, totalDetected: length(loop_events)})
  end

  operation(:api_phases,
    summary: "Get API phase events for a run",
    parameters: [id: [in: :path, type: :string, required: true, description: "Run ID"]],
    responses: [
      ok:
        {"Phase events", "application/json",
         %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}}}
    ]
  )

  def api_phases(conn, %{"id" => run_id}) do
    events = safe_call(fn -> TraceReader.events_for_run(run_id) end, [])

    phases =
      events
      |> Enum.filter(fn event ->
        Map.get(event, "eventType") in ["phase_started", "phase_completed", "phase_failed"]
      end)
      |> Enum.group_by(fn event -> Map.get(event, "phaseIndex", 0) end)
      |> Enum.map(fn {idx, phase_events} ->
        %{phaseIndex: idx, events: phase_events, eventCount: length(phase_events)}
      end)
      |> Enum.sort_by(& &1.phaseIndex)

    json(conn, phases)
  end

  defp serialize_trace_run(run) do
    %{
      id: Map.get(run, :run_id),
      workflowType: Map.get(run, :workflow_name),
      workspacePath: Map.get(run, :workspace_path),
      status: Map.get(run, :status),
      phaseCount: Map.get(run, :phase_count),
      budgetUsd: nil,
      tokensTotal: Map.get(run, :total_tokens, 0),
      costUsd: Map.get(run, :total_cost_usd, 0.0),
      clientId: Map.get(run, :client_id)
    }
  end

  defp serialize_run_detail(run_id, manifest, summary) do
    phases =
      cond do
        is_map(manifest) and is_list(manifest["phases"]) ->
          Enum.map(manifest["phases"], &serialize_manifest_phase/1)

        is_map(summary) and is_list(summary[:phases]) ->
          Enum.map(summary.phases, &serialize_summary_phase/1)

        true ->
          []
      end

    total_tokens =
      if is_map(summary) do
        (summary[:total_input_tokens] || 0) + (summary[:total_output_tokens] || 0)
      else
        0
      end

    %{
      id: run_id,
      workflowType:
        (manifest && (manifest["workflow_name"] || manifest["name"])) ||
          (summary && summary[:workflow_name]) ||
          "unknown",
      workspacePath: manifest && (manifest["workspace_path"] || manifest["workspacePath"]),
      status: (manifest && manifest["status"]) || "unknown",
      budgetUsd: nil,
      branch: manifest && manifest["branch"],
      planSummary:
        (manifest && manifest["plan_summary"]) || (manifest && manifest["planSummary"]),
      phases: phases,
      totalTokens: total_tokens,
      totalCostUsd: summary && summary[:total_cost_usd]
    }
  end

  defp serialize_manifest_phase(phase) do
    %{
      id: phase["id"] || phase["phaseId"],
      name: phase["name"] || phase["phaseName"],
      type: phase["type"],
      status: phase["status"],
      retryCount: phase["retryCount"] || phase["retry_count"] || 0,
      maxRetries: phase["maxRetries"] || phase["max_retries"] || 0,
      dependsOn: phase["dependsOn"] || phase["depends_on"] || []
    }
  end

  defp serialize_summary_phase(phase) do
    %{
      id: phase.id,
      name: phase.name,
      type: phase.phase_type,
      status: phase.status,
      retryCount: phase.retry_count || 0,
      maxRetries: phase.max_retries || 0,
      dependsOn: []
    }
  end

  defp parse_pagination(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit", @default_limit)),
         {:ok, offset} <- parse_offset(Map.get(params, "offset", 0)) do
      {:ok, limit, offset}
    end
  end

  defp parse_limit(val) do
    case parse_int(val) do
      {:ok, n} when n >= 1 and n <= @max_limit -> {:ok, n}
      {:ok, _} -> {:error, :limit, "must be between 1 and #{@max_limit}"}
      :error -> {:error, :limit, "must be a positive integer"}
    end
  end

  defp parse_offset(val) do
    case parse_int(val) do
      {:ok, n} when n >= 0 -> {:ok, n}
      {:ok, _} -> {:error, :offset, "must be 0 or greater"}
      :error -> {:error, :offset, "must be a non-negative integer"}
    end
  end

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> {:ok, n}
      :error -> :error
    end
  end

  defp parse_int(val) when is_integer(val), do: {:ok, val}
  defp parse_int(_), do: :error

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
