defmodule CrucibleWeb.Api.AuditController do
  use CrucibleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Crucible.{Audit, AuditLog}
  alias CrucibleWeb.Api.ErrorCodes

  action_fallback CrucibleWeb.Api.FallbackController

  @valid_actions MapSet.new([
                   # JSONL-originated (TS dashboard)
                   "login", "logout", "config.update", "env.update", "budget.update",
                   "workflow.trigger", "workflow.view", "client.create", "client.update",
                   "client.delete", "client.team.add", "client.team.remove",
                   "client.config.update", "kanban.card.move", "kanban.card.create",
                   "kanban.card.update", "circuit.reset", "remote.session.start",
                   "remote.session.kill", "audit.query",
                   # DB-native event types
                   "created", "updated", "deleted", "moved", "archived", "restored",
                   "status_changed", "card_linked", "cancelled", "completed", "failed",
                   "upserted", "member_added", "member_removed"
                 ])

  operation(:index,
    summary: "Query audit trail",
    description: "Returns paginated audit events with optional filters by user, client, action type, and date range.",
    tags: ["Audit"],
    parameters: [
      limit: [in: :query, type: :integer, required: false, description: "Max events to return (1–100, default 50)"],
      offset: [in: :query, type: :integer, required: false, description: "Pagination offset (default 0)"],
      userId: [in: :query, type: :string, required: false, description: "Filter by actor user ID"],
      clientId: [in: :query, type: :string, required: false, description: "Filter by client ID"],
      action: [in: :query, type: :string, required: false, description: "Filter by action type (must be a supported audit action)"],
      from: [in: :query, type: :string, required: false, description: "Start date filter (ISO 8601 date)"],
      to: [in: :query, type: :string, required: false, description: "End date filter (ISO 8601 date)"]
    ],
    responses: [
      ok: {"Audit events", "application/json", %OpenApiSpex.Schema{type: :object}},
      bad_request: {"Validation error", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )
  def index(conn, params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit", "50")),
         {:ok, offset} <- parse_offset(Map.get(params, "offset", "0")),
         {:ok, action} <- parse_action(Map.get(params, "action")),
         {:ok, from} <- parse_date_param(Map.get(params, "from")),
         {:ok, to} <- parse_date_param(Map.get(params, "to")),
         {:ok, result} <-
           query_audit_trail(
             limit: limit,
             offset: offset,
             user_id: Map.get(params, "userId") || Map.get(params, "user_id"),
             client_id: Map.get(params, "clientId") || Map.get(params, "client_id"),
             action: action,
             from: from,
             to: to
           ) do
      log_query(conn, params)
      json(conn, %{events: result.events, total: result.total, limit: limit, offset: offset})
    else
      {:error, :invalid_limit} ->
        conn
        |> put_status(400)
        |> json(%{error: ErrorCodes.invalid_params(%{limit: "must be between 1 and 100"})})

      {:error, :invalid_offset} ->
        conn
        |> put_status(400)
        |> json(%{error: ErrorCodes.invalid_params(%{offset: "must be 0 or greater"})})

      {:error, :invalid_action} ->
        conn
        |> put_status(400)
        |> json(%{error: ErrorCodes.invalid_params(%{action: "is not a supported audit action"})})

      {:error, :invalid_date} ->
        conn
        |> put_status(400)
        |> json(%{error: ErrorCodes.invalid_params(%{date: "must be an ISO 8601 timestamp"})})
    end
  end

  defp parse_limit(val) do
    case parse_int(val) do
      {:ok, n} when n >= 1 and n <= 100 -> {:ok, n}
      {:ok, _} -> {:error, :invalid_limit}
      :error -> {:error, :invalid_limit}
    end
  end

  defp parse_offset(val) do
    case parse_int(val) do
      {:ok, n} when n >= 0 -> {:ok, n}
      {:ok, _} -> {:error, :invalid_offset}
      :error -> {:error, :invalid_offset}
    end
  end

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} -> {:ok, n}
      {n, _} -> {:ok, n}
      :error -> :error
    end
  end

  defp parse_int(val) when is_integer(val), do: {:ok, val}
  defp parse_int(_), do: :error

  defp parse_action(nil), do: {:ok, nil}
  defp parse_action(""), do: {:ok, nil}

  defp parse_action(action) when is_binary(action) do
    if MapSet.member?(@valid_actions, action), do: {:ok, action}, else: {:error, :invalid_action}
  end

  defp parse_date_param(nil), do: {:ok, nil}
  defp parse_date_param(""), do: {:ok, nil}

  defp parse_date_param(value) when is_binary(value) do
    if Regex.match?(~r/^\d{4}-\d{2}-\d{2}/, value),
      do: {:ok, value},
      else: {:error, :invalid_date}
  end

  defp query_audit_trail(opts) do
    from_dt = parse_datetime(Keyword.get(opts, :from))
    to_dt = parse_datetime(Keyword.get(opts, :to))
    actor = Keyword.get(opts, :user_id)

    db_opts =
      [
        limit: Keyword.fetch!(opts, :limit),
        offset: Keyword.fetch!(opts, :offset),
        event_type: Keyword.get(opts, :action),
        from: from_dt,
        to: to_dt
      ]
      |> then(fn o -> if actor, do: Keyword.put(o, :actor, actor), else: o end)

    {events, total} = Audit.list_events(db_opts)

    # Serialize to backward-compatible JSONL API shape
    serialized =
      Enum.map(events, fn evt ->
        %{
          timestamp: if(evt.occurred_at, do: DateTime.to_iso8601(evt.occurred_at)),
          userId: evt.actor,
          action: evt.event_type,
          resource: "#{evt.entity_type}/#{evt.entity_id}",
          details: evt.payload
        }
      end)

    {:ok, %{events: serialized, total: total}}
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str <> "T00:00:00Z") do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp log_query(conn, params) do
    user = conn.assigns[:current_user] || %{}
    actor = if user[:id], do: "api:#{user[:id]}", else: "api:anonymous"

    AuditLog.log("audit", "query", "audit.query", %{
      filters: %{
        userId: Map.get(params, "userId") || Map.get(params, "user_id"),
        clientId: Map.get(params, "clientId") || Map.get(params, "client_id"),
        action: Map.get(params, "action"),
        from: Map.get(params, "from"),
        to: Map.get(params, "to")
      }
    }, actor: actor)
  end

end
