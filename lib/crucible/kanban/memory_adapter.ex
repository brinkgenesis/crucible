defmodule Crucible.Kanban.MemoryAdapter do
  @moduledoc """
  In-memory kanban tracker for tests.
  Stores cards in an Agent process.
  """
  @behaviour Crucible.Kanban.Tracker

  use Agent

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{cards: %{}, events: []} end, name: name)
  end

  @impl true
  def list_cards(filters \\ []) do
    archived = Keyword.get(filters, :archived, false)
    client_id = Keyword.get(filters, :client_id)

    cards =
      Agent.get(__MODULE__, fn state ->
        state.cards
        |> Map.values()
        |> Enum.filter(&(&1.archived == archived))
        |> Enum.filter(fn card ->
          is_nil(client_id) or Map.get(card, :client_id) == client_id
        end)
        |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
      end)

    {:ok, cards}
  end

  @impl true
  def get_card(id) do
    case Agent.get(__MODULE__, &Map.get(&1.cards, id)) do
      nil -> {:error, :not_found}
      card -> {:ok, card}
    end
  end

  @impl true
  def create_card(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    card = %{
      id: Map.get(attrs, :id, generate_id()),
      title: Map.fetch!(attrs, :title),
      column: Map.get(attrs, :column, "unassigned"),
      version: 0,
      archived: false,
      metadata: Map.get(attrs, :metadata, %{}),
      client_id: Map.get(attrs, :client_id),
      inserted_at: now,
      updated_at: now
    }

    Agent.update(__MODULE__, fn state ->
      %{state | cards: Map.put(state.cards, card.id, card)}
    end)

    {:ok, card}
  end

  @impl true
  def move_card(id, column) do
    Agent.get(__MODULE__, fn state -> Map.get(state.cards, id) end)
    |> case do
      nil -> {:error, :not_found}
      card -> move_card(id, column, card.version)
    end
  end

  @impl true
  def move_card(id, column, version) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.cards, id) do
        nil ->
          {{:error, :not_found}, state}

        card when card.version != version ->
          {{:error, :version_conflict}, state}

        card ->
          updated = %{card | column: column, version: version + 1, updated_at: DateTime.utc_now()}
          state = %{state | cards: Map.put(state.cards, id, updated)}
          {{:ok, updated}, state}
      end
    end)
  end

  @impl true
  def update_card(id, attrs) do
    Agent.get(__MODULE__, fn state -> Map.get(state.cards, id) end)
    |> case do
      nil -> {:error, :not_found}
      card -> update_card(id, attrs, card.version)
    end
  end

  @impl true
  def update_card(id, attrs, version) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.cards, id) do
        nil ->
          {{:error, :not_found}, state}

        card when card.version != version ->
          {{:error, :version_conflict}, state}

        card ->
          updated =
            card
            |> Map.merge(Map.drop(attrs, [:id, :version]))
            |> Map.put(:version, version + 1)
            |> Map.put(:updated_at, DateTime.utc_now())

          state = %{state | cards: Map.put(state.cards, id, updated)}
          {{:ok, updated}, state}
      end
    end)
  end

  @impl true
  def archive_card(id) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.cards, id) do
        nil ->
          {{:error, :not_found}, state}

        card ->
          updated = %{card | archived: true, updated_at: DateTime.utc_now()}
          state = %{state | cards: Map.put(state.cards, id, updated)}
          {{:ok, updated}, state}
      end
    end)
  end

  @impl true
  def restore_card(id) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.cards, id) do
        nil ->
          {{:error, :not_found}, state}

        card ->
          updated = %{card | archived: false, updated_at: DateTime.utc_now()}
          state = %{state | cards: Map.put(state.cards, id, updated)}
          {{:ok, updated}, state}
      end
    end)
  end

  @impl true
  def delete_card(id) do
    Agent.get_and_update(__MODULE__, fn state ->
      if Map.has_key?(state.cards, id) do
        state = %{state | cards: Map.delete(state.cards, id)}
        {:ok, state}
      else
        {{:error, :not_found}, state}
      end
    end)
  end

  @impl true
  def card_history(id, _opts \\ []) do
    events =
      Agent.get(__MODULE__, fn state ->
        Enum.filter(state.events, &(&1.card_id == id))
      end)

    {:ok, events}
  end

  @impl true
  def log_card_event(card_id, event_type, payload \\ %{}) do
    event = %{
      id: generate_id(),
      card_id: card_id,
      event_type: event_type,
      payload: payload,
      occurred_at: DateTime.utc_now()
    }

    Agent.update(__MODULE__, fn state ->
      %{state | events: [event | state.events]}
    end)

    {:ok, event}
  end

  defp generate_id,
    do: :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
end
