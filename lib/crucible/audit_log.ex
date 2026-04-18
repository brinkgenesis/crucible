defmodule Crucible.AuditLog do
  @moduledoc """
  Append-only audit trail for entity mutations.

  Records structured audit events via `log/4` and retrieves them via `history/3`.
  Each event captures an entity type, entity ID, event type, and an arbitrary payload
  map, timestamped at insertion. Events are persisted through the `AuditEvent` schema
  and surfaced in the `AuditLive` LiveView page.

  Logging is intentionally fail-safe — errors are caught and logged as warnings so
  that audit failures never block the calling mutation.
  """

  import Ecto.Query
  require Logger

  alias Crucible.Repo
  alias Crucible.Schema.AuditEvent

  @doc """
  Log an audit event. Fails silently to avoid blocking mutations.

  Optional `opts`:
    * `:actor` — who triggered the mutation (e.g. `"liveview:ConfigLive"`, `"system:kanban"`)
  """
  @spec log(String.t(), String.t(), String.t(), map(), keyword()) :: :ok
  def log(entity_type, entity_id, event_type, payload \\ %{}, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    attrs =
      %{
        entity_type: entity_type,
        entity_id: to_string(entity_id),
        event_type: event_type,
        payload: payload,
        occurred_at: DateTime.utc_now()
      }
      |> then(fn a -> if actor, do: Map.put(a, :actor, actor), else: a end)

    %AuditEvent{}
    |> AuditEvent.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("AuditLog: failed to log #{entity_type}/#{event_type}: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("AuditLog: exception logging #{entity_type}/#{event_type}: #{inspect(e)}")
      :ok
  end

  @doc """
  Build an audit payload from an Ecto changeset, capturing before/after values.

  Returns a map like `%{changes: %{field => %{from: old, to: new}}}` merged with `extra`.
  Skips metadata fields (`:updated_at`, `:inserted_at`).
  """
  @spec diff_payload(Ecto.Changeset.t(), map()) :: map()
  def diff_payload(%Ecto.Changeset{} = changeset, extra \\ %{}) do
    skip = [:updated_at, :inserted_at]

    changes =
      changeset.changes
      |> Map.drop(skip)
      |> Map.new(fn {field, new_val} ->
        old_val = Map.get(changeset.data, field)
        {field, %{from: serialize_value(old_val), to: serialize_value(new_val)}}
      end)

    Map.merge(%{changes: changes}, extra)
  end

  defp serialize_value(%Decimal{} = d), do: Decimal.to_string(d)
  defp serialize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_value(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp serialize_value(val) when is_list(val), do: val
  defp serialize_value(val), do: val

  @doc "Query audit history for an entity."
  @spec history(String.t(), String.t(), keyword()) :: [AuditEvent.t()]
  def history(entity_type, entity_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    AuditEvent
    |> where([e], e.entity_type == ^entity_type and e.entity_id == ^to_string(entity_id))
    |> order_by([e], desc: e.occurred_at)
    |> limit(^limit)
    |> Repo.all()
  rescue
    _ -> []
  end
end
