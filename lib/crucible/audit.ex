defmodule Crucible.Audit do
  @moduledoc """
  Context module for audit-related queries against the `audit_events` table.
  """

  import Ecto.Query

  alias Crucible.Repo
  alias Crucible.Schema.AuditEvent

  @type health :: %{event_count: non_neg_integer(), latest_timestamp: DateTime.t() | nil}

  @doc """
  Returns a health summary of the audit events table: total event count
  and the most recent `inserted_at` timestamp.
  """
  @spec health_check() :: health()
  def health_check do
    result =
      from(e in AuditEvent,
        select: {count(e.id), max(e.inserted_at)}
      )
      |> Repo.one()

    case result do
      {count, latest} -> %{event_count: count, latest_timestamp: latest}
      _ -> %{event_count: 0, latest_timestamp: nil}
    end
  end

  @doc """
  Query audit events with filtering and pagination.

  ## Options

    * `:limit` — max results (default 50)
    * `:offset` — skip N results (default 0)
    * `:event_type` — filter by event type string
    * `:entity_type` — filter by entity type string
    * `:from` — earliest occurred_at (DateTime)
    * `:to` — latest occurred_at (DateTime)

  Returns `{events, total}`.
  """
  @spec list_events(keyword()) :: {[AuditEvent.t()], non_neg_integer()}
  def list_events(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    base = from(e in AuditEvent)

    filtered =
      base
      |> maybe_filter(:event_type, Keyword.get(opts, :event_type))
      |> maybe_filter(:entity_type, Keyword.get(opts, :entity_type))
      |> maybe_filter(:actor, Keyword.get(opts, :actor))
      |> maybe_filter_from(Keyword.get(opts, :from))
      |> maybe_filter_to(Keyword.get(opts, :to))

    total = Repo.aggregate(filtered, :count)

    events =
      filtered
      |> order_by([e], desc: e.occurred_at)
      |> limit(^limit)
      |> offset(^offset)
      |> Repo.all()

    {events, total}
  rescue
    _ -> {[], 0}
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query
  defp maybe_filter(query, :event_type, val), do: where(query, [e], e.event_type == ^val)
  defp maybe_filter(query, :entity_type, val), do: where(query, [e], e.entity_type == ^val)
  defp maybe_filter(query, :actor, val), do: where(query, [e], e.actor == ^val)

  defp maybe_filter_from(query, nil), do: query
  defp maybe_filter_from(query, dt), do: where(query, [e], e.occurred_at >= ^dt)

  defp maybe_filter_to(query, nil), do: query
  defp maybe_filter_to(query, dt), do: where(query, [e], e.occurred_at <= ^dt)
end
