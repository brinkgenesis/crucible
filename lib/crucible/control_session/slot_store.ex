defmodule Crucible.ControlSession.SlotStore do
  @moduledoc """
  ETS-backed state management and PubSub broadcasting for control slots.

  Provides helpers for reading, writing, and broadcasting slot state.
  The ETS table is owned by the ControlSession GenServer but read
  concurrently by LiveView processes.
  """

  @table :control_sessions
  @max_slots 6
  @pubsub Crucible.PubSub
  @topic "control:sessions"
  @output_poll_ms 1_000

  @doc "Returns a slot by id, falling back to an empty slot if not found."
  @spec get(pos_integer()) :: map()
  def get(slot_id) do
    case :ets.whereis(@table) do
      :undefined ->
        empty(slot_id)

      _ref ->
        case :ets.lookup(@table, slot_id) do
          [{^slot_id, slot}] -> slot
          [] -> empty(slot_id)
        end
    end
  end

  @doc "Merges updates into an existing slot and writes it back to ETS."
  @spec update(pos_integer(), map()) :: true
  def update(slot_id, updates) do
    slot = get(slot_id)
    updated = Map.merge(slot, updates)
    :ets.insert(@table, {slot_id, updated})
  end

  @doc "Resets a slot to its empty default and writes it back to ETS."
  @spec reset(pos_integer()) :: true
  def reset(slot_id) do
    :ets.insert(@table, {slot_id, empty(slot_id)})
  end

  @doc "Returns all slots as a list."
  @spec list_all() :: [map()]
  def list_all do
    Enum.map(1..@max_slots, &get/1)
  end

  @doc "Initializes the ETS table and all empty slots. Idempotent."
  @spec init_table() :: :ets.table()
  def init_table do
    table =
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
      else
        @table
      end

    for id <- 1..@max_slots do
      :ets.insert(table, {id, empty(id)})
    end

    table
  end

  @doc "Broadcasts the current slot list via PubSub."
  @spec broadcast_update() :: :ok | {:error, term()}
  def broadcast_update do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:control_updated, list_all()})
  end

  @doc "Schedules the next output poll message."
  @spec schedule_output_poll() :: reference()
  def schedule_output_poll do
    Process.send_after(self(), :poll_output, @output_poll_ms)
  end

  @doc "Returns the default empty slot map for the given id."
  @spec empty(pos_integer()) :: map()
  def empty(id) do
    %{
      id: id,
      status: :empty,
      cwd: nil,
      model: "claude-sonnet-4-6",
      tmux_session: nil,
      started_at: nil,
      last_output: "",
      error: nil
    }
  end
end
