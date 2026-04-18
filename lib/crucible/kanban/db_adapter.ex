defmodule Crucible.Kanban.DbAdapter do
  @moduledoc """
  Ecto-backed kanban tracker. Replaces the Kysely-based kanban routes.
  Supports optimistic locking via version field and event logging.
  """
  @behaviour Crucible.Kanban.Tracker

  alias Crucible.AuditLog
  alias Crucible.Repo
  alias Crucible.Schema.{Card, CardEvent}

  import Ecto.Query

  @impl true
  def list_cards(filters \\ []) do
    archived = Keyword.get(filters, :archived, false)
    client_id = Keyword.get(filters, :client_id)

    query =
      Card
      |> where([c], c.archived == ^archived)
      |> order_by([c], desc: c.updated_at)

    query = if client_id, do: where(query, [c], c.client_id == ^client_id), else: query

    {:ok, Repo.all(query)}
  end

  @impl true
  def get_card(id) do
    case Repo.get(Card, id) do
      nil -> {:error, :not_found}
      card -> {:ok, card}
    end
  end

  @impl true
  def create_card(attrs) do
    id = Map.get(attrs, :id) || Map.get(attrs, "id") || Ecto.UUID.generate()

    result =
      Repo.transaction(fn ->
        card =
          %Card{id: id}
          |> Card.changeset(attrs)
          |> Repo.insert!()

        log_event(card.id, "card_created", %{column: card.column, title: card.title})
        card
      end)

    case result do
      {:ok, card} ->
        broadcast(:card_created, card)
        AuditLog.log("card", card.id, "created", %{column: card.column, title: card.title}, actor: "system:kanban")
        {:ok, card}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def move_card(id, column) do
    case Repo.get(Card, id) do
      nil -> {:error, :not_found}
      card -> move_card(id, column, card.version)
    end
  end

  @impl true
  def move_card(id, column, version) do
    column_str = to_string(column)

    result =
      Repo.transaction(fn ->
        card = Repo.get!(Card, id)

        if card.version != version do
          Repo.rollback(:version_conflict)
        end

        old_column = card.column

        card
        |> Card.changeset(%{
          column: column_str,
          version: version + 1,
          metadata: merge_metadata(card.metadata, move_metadata(column_str))
        })
        |> Repo.update!()
        |> tap(fn _ ->
          log_event(id, "card_moved", %{from: old_column, to: column_str})
        end)
      end)

    case result do
      {:ok, card} ->
        broadcast(:card_moved, card)
        AuditLog.log("card", id, "moved", %{column: column_str}, actor: "system:kanban")
        {:ok, card}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def update_card(id, attrs) do
    case Repo.get(Card, id) do
      nil -> {:error, :not_found}
      card -> update_card(id, attrs, card.version)
    end
  end

  @impl true
  def update_card(id, attrs, version) do
    result =
      Repo.transaction(fn ->
        card = Repo.get!(Card, id)

        if card.version != version do
          Repo.rollback(:version_conflict)
        end

        # Merge metadata rather than replacing
        merged_metadata =
          if Map.has_key?(attrs, :metadata) do
            merge_metadata(card.metadata, attrs.metadata)
          else
            card.metadata
          end

        update_attrs =
          attrs
          |> Map.put(:version, version + 1)
          |> Map.put(:metadata, merged_metadata)

        changeset = Card.changeset(card, update_attrs)
        updated_card = Repo.update!(changeset)
        log_event(id, "card_updated", %{fields: Map.keys(attrs)})
        {updated_card, changeset}
      end)

    case result do
      {:ok, {card, changeset}} ->
        broadcast(:card_updated, card)
        AuditLog.log("card", id, "updated", AuditLog.diff_payload(changeset), actor: "system:kanban")
        {:ok, card}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def archive_card(id) do
    result =
      Repo.transaction(fn ->
        card = Repo.get!(Card, id)

        now = DateTime.utc_now() |> DateTime.truncate(:second)

        # Archive the card
        card
        |> Card.changeset(%{archived: true, archived_at: now})
        |> Repo.update!()

        # Cascade: archive children
        Card
        |> where([c], c.parent_card_id == ^id and c.archived == false)
        |> Repo.update_all(set: [archived: true, archived_at: now])

        log_event(id, "card_archived", %{})
        Repo.get!(Card, id)
      end)

    case result do
      {:ok, card} ->
        broadcast(:card_archived, card)
        AuditLog.log("card", id, "archived", %{}, actor: "system:kanban")
        {:ok, card}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def restore_card(id) do
    result =
      Repo.transaction(fn ->
        card = Repo.get!(Card, id)

        card
        |> Card.changeset(%{archived: false, archived_at: nil})
        |> Repo.update!()
        |> tap(fn _ -> log_event(id, "card_restored", %{}) end)
      end)

    case result do
      {:ok, card} ->
        broadcast(:card_restored, card)
        AuditLog.log("card", id, "restored", %{}, actor: "system:kanban")
        {:ok, card}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def delete_card(id) do
    result =
      Repo.transaction(fn ->
        # Delete events first (FK constraint)
        CardEvent
        |> where([e], e.card_id == ^id)
        |> Repo.delete_all()

        case Repo.get(Card, id) do
          nil -> Repo.rollback(:not_found)
          card -> Repo.delete!(card)
        end
      end)

    case result do
      {:ok, _} ->
        broadcast(:card_deleted, %{id: id})
        AuditLog.log("card", id, "deleted", %{}, actor: "system:kanban")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def card_history(id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> min(200) |> max(1)
    offset = Keyword.get(opts, :offset, 0)

    events =
      CardEvent
      |> where([e], e.card_id == ^id)
      |> order_by([e], desc: e.occurred_at)
      |> limit(^limit)
      |> offset(^offset)
      |> Repo.all()

    {:ok, events}
  end

  @impl true
  def log_card_event(card_id, event_type, payload \\ %{}) do
    %CardEvent{}
    |> CardEvent.changeset(%{
      card_id: card_id,
      event_type: event_type,
      payload: payload,
      occurred_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  # --- Private ---

  defp log_event(card_id, event_type, payload) do
    %CardEvent{}
    |> CardEvent.changeset(%{
      card_id: card_id,
      event_type: event_type,
      payload: payload,
      occurred_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp move_metadata("todo"),
    do: %{"movedToTodoAt" => DateTime.utc_now() |> DateTime.to_iso8601()}

  defp move_metadata(_), do: %{}

  defp merge_metadata(nil, new), do: new
  defp merge_metadata(existing, nil), do: existing

  defp merge_metadata(existing, new) when is_map(existing) and is_map(new),
    do: Map.merge(existing, new)

  defp merge_metadata(_existing, new), do: new

  defp broadcast(event, data) do
    Phoenix.PubSub.broadcast(Crucible.PubSub, "kanban:cards", {event, data})
  end
end
