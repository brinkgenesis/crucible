defmodule CrucibleWeb.Api.TracesController do
  use CrucibleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Crucible.TraceReader

  operation(:index,
    summary: "List trace events",
    description: "Returns trace events, optionally filtered by runId, client_id, or workspace.",
    tags: ["Traces"],
    parameters: [
      limit: [
        in: :query,
        type: :integer,
        required: false,
        description: "Max events to return (default 50)"
      ],
      runId: [in: :query, type: :string, required: false, description: "Filter by run ID"],
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
        {"Trace events", "application/json",
         %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}}}
    ]
  )

  def index(conn, params) do
    {:ok, limit} = get_int(params, "limit", 50)
    run_id = Map.get(params, "runId")
    client_id = blank_to_nil(Map.get(params, "client_id") || Map.get(params, "clientId"))
    workspace = blank_to_nil(Map.get(params, "workspace"))

    events =
      cond do
        run_id ->
          if run_in_scope?(run_id, client_id, workspace) do
            TraceReader.events_for_run(run_id, limit: limit)
          else
            []
          end

        client_id || workspace ->
          scoped_events(limit, client_id, workspace)

        true ->
          TraceReader.all_events(limit: limit)
      end

    json(conn, events)
  end

  operation(:show,
    summary: "Get a single trace event",
    description: "Returns a single trace event by its ID.",
    tags: ["Traces"],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Event ID"]
    ],
    responses: [
      ok: {"Trace event", "application/json", %OpenApiSpex.Schema{type: :object}},
      not_found: {"Not found", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def show(conn, %{"id" => id}) do
    events = TraceReader.all_events(limit: 1000)

    case Enum.find(events, &(Map.get(&1, "id") == id)) do
      nil -> error_json(conn, 404, "not_found", "Resource not found")
      event -> json(conn, event)
    end
  end

  operation(:export,
    summary: "Export run traces as NDJSON",
    description: "Downloads all trace events for a run as a NDJSON file attachment.",
    tags: ["Traces"],
    parameters: [
      run_id: [in: :path, type: :string, required: true, description: "Run ID to export"],
      client_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Scope filter: client ID"
      ],
      workspace: [
        in: :query,
        type: :string,
        required: false,
        description: "Scope filter: workspace path"
      ]
    ],
    responses: [
      ok: {"NDJSON trace export", "application/x-ndjson", %OpenApiSpex.Schema{type: :string}}
    ]
  )

  def export(conn, %{"run_id" => run_id} = params) do
    client_id = blank_to_nil(Map.get(params, "client_id") || Map.get(params, "clientId"))
    workspace = blank_to_nil(Map.get(params, "workspace"))

    if run_in_scope?(run_id, client_id, workspace) do
      events = TraceReader.events_for_run(run_id, limit: 10_000)

      conn
      |> put_resp_content_type("application/x-ndjson")
      |> put_resp_header("content-disposition", "attachment; filename=\"traces-#{run_id}.jsonl\"")
      |> send_resp(200, Enum.map_join(events, "\n", &Jason.encode!/1))
    else
      error_json(conn, 404, "not_found", "Resource not found")
    end
  end

  operation(:dashboard,
    summary: "Trace dashboard summary",
    description:
      "Returns a summary of all runs with event counts, optionally scoped to client or workspace.",
    tags: ["Traces"],
    parameters: [
      client_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Scope filter: client ID"
      ],
      workspace: [
        in: :query,
        type: :string,
        required: false,
        description: "Scope filter: workspace path"
      ]
    ],
    responses: [ok: {"Dashboard summary", "application/json", %OpenApiSpex.Schema{type: :object}}]
  )

  def dashboard(conn, params) do
    client_id = blank_to_nil(Map.get(params, "client_id") || Map.get(params, "clientId"))
    workspace = blank_to_nil(Map.get(params, "workspace"))

    runs =
      TraceReader.list_runs(client_id: client_id, workspace: workspace)
      |> Enum.take(50)
      |> Enum.map(fn run ->
        %{
          runId: run.run_id,
          eventCount: run.event_count,
          firstEvent: run.started_at,
          lastEvent: run.ended_at || run.started_at
        }
      end)
      |> Enum.sort_by(&(&1.lastEvent || ""), :desc)

    json(conn, %{runs: runs, totalEvents: Enum.reduce(runs, 0, &(&1.eventCount + &2))})
  end

  operation(:detail,
    summary: "Run trace detail",
    description: "Returns all trace events for a specific run.",
    tags: ["Traces"],
    parameters: [
      run_id: [in: :path, type: :string, required: true, description: "Run ID"],
      client_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Scope filter: client ID"
      ],
      workspace: [
        in: :query,
        type: :string,
        required: false,
        description: "Scope filter: workspace path"
      ]
    ],
    responses: [
      ok: {"Run detail with events", "application/json", %OpenApiSpex.Schema{type: :object}},
      not_found: {"Not found", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def detail(conn, %{"run_id" => run_id} = params) do
    client_id = blank_to_nil(Map.get(params, "client_id") || Map.get(params, "clientId"))
    workspace = blank_to_nil(Map.get(params, "workspace"))

    if run_in_scope?(run_id, client_id, workspace) do
      events = TraceReader.events_for_run(run_id, limit: 1000)

      if events == [] do
        error_json(conn, 404, "not_found", "Resource not found")
      else
        json(conn, %{runId: run_id, events: events, eventCount: length(events)})
      end
    else
      error_json(conn, 404, "not_found", "Resource not found")
    end
  end

  operation(:summary,
    summary: "Run trace summary",
    description: "Returns aggregated event counts by type and total cost for a run.",
    tags: ["Traces"],
    parameters: [
      run_id: [in: :path, type: :string, required: true, description: "Run ID"],
      client_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Scope filter: client ID"
      ],
      workspace: [
        in: :query,
        type: :string,
        required: false,
        description: "Scope filter: workspace path"
      ]
    ],
    responses: [
      ok: {"Run summary", "application/json", %OpenApiSpex.Schema{type: :object}},
      not_found: {"Not found", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def summary(conn, %{"run_id" => run_id} = params) do
    client_id = blank_to_nil(Map.get(params, "client_id") || Map.get(params, "clientId"))
    workspace = blank_to_nil(Map.get(params, "workspace"))

    if run_in_scope?(run_id, client_id, workspace) do
      events = TraceReader.events_for_run(run_id, limit: 5000)

      by_type = Enum.frequencies_by(events, fn e -> Map.get(e, "eventType", "unknown") end)

      total_cost =
        events
        |> Enum.map(&event_cost_usd/1)
        |> Enum.sum()

      json(conn, %{
        runId: run_id,
        eventCount: length(events),
        byType: by_type,
        totalCostUsd: Float.round(total_cost * 1.0, 4)
      })
    else
      error_json(conn, 404, "not_found", "Resource not found")
    end
  end

  defp scoped_events(limit, client_id, workspace) do
    runs = TraceReader.list_runs(client_id: client_id, workspace: workspace) |> Enum.take(50)
    run_ids = Enum.map(runs, & &1.run_id)
    per_run_limit = max(div(limit, max(length(run_ids), 1)), 5)

    run_ids
    |> Enum.flat_map(&TraceReader.events_for_run(&1, limit: per_run_limit))
    |> Enum.sort_by(&(Map.get(&1, "timestamp") || ""), :desc)
    |> Enum.take(limit)
  end

  defp run_in_scope?(run_id, nil, nil) when is_binary(run_id) and run_id != "", do: true

  defp run_in_scope?(run_id, client_id, workspace) do
    # list_runs is cached (5s RollupCache). Use MapSet for O(1) membership check.
    TraceReader.list_runs(client_id: client_id, workspace: workspace)
    |> MapSet.new(& &1.run_id)
    |> MapSet.member?(run_id)
  end

  defp event_cost_usd(event) do
    metadata = Map.get(event, "metadata") || %{}
    value = Map.get(metadata, "costUsd")

    cond do
      is_float(value) -> value
      is_integer(value) -> value * 1.0
      true -> 0.0
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
