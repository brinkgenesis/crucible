defmodule Crucible.PubSub.TopicRegistry do
  @moduledoc """
  GenServer-based topic registry that tracks subscriber PIDs per PubSub topic.

  Provides fast subscriber lookup and delegates to Manifold for partitioned sends.
  Monitors subscriber processes and cleans up on exit. Emits telemetry events
  for observability.

  ## Usage

      TopicRegistry.subscribe("kanban:cards")
      TopicRegistry.broadcast("kanban:cards", {:card_updated, card})
      TopicRegistry.subscribers("kanban:cards")
  """

  use GenServer
  require Logger

  @type topic :: String.t()

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Subscribe the calling process to a topic."
  @spec subscribe(topic()) :: :ok
  def subscribe(topic) do
    GenServer.call(__MODULE__, {:subscribe, topic, self()})
  end

  @doc "Unsubscribe the calling process from a topic."
  @spec unsubscribe(topic()) :: :ok
  def unsubscribe(topic) do
    GenServer.call(__MODULE__, {:unsubscribe, topic, self()})
  end

  @doc "Broadcast a message to all subscribers of a topic via Manifold."
  @spec broadcast(topic(), term()) :: :ok
  def broadcast(topic, message) do
    GenServer.call(__MODULE__, {:broadcast, topic, message})
  end

  @doc "Return the list of subscriber PIDs for a topic."
  @spec subscribers(topic()) :: [pid()]
  def subscribers(topic) do
    GenServer.call(__MODULE__, {:subscribers, topic})
  end

  @doc "Return a map of topic => subscriber count for monitoring."
  @spec stats() :: %{topic() => non_neg_integer()}
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    # topic => MapSet of pids
    {:ok, %{topics: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:subscribe, topic, pid}, _from, state) do
    subs = Map.get(state.topics, topic, MapSet.new())
    new_subs = MapSet.put(subs, pid)
    new_topics = Map.put(state.topics, topic, new_subs)

    # Monitor the pid if not already monitored
    new_monitors =
      if Map.has_key?(state.monitors, pid) do
        state.monitors
      else
        ref = Process.monitor(pid)
        Map.put(state.monitors, pid, ref)
      end

    :telemetry.execute(
      [:crucible, :pubsub, :subscribe],
      %{subscriber_count: MapSet.size(new_subs)},
      %{topic: topic, pid: pid}
    )

    {:reply, :ok, %{state | topics: new_topics, monitors: new_monitors}}
  end

  def handle_call({:unsubscribe, topic, pid}, _from, state) do
    subs = Map.get(state.topics, topic, MapSet.new())
    new_subs = MapSet.delete(subs, pid)

    new_topics =
      if MapSet.size(new_subs) == 0,
        do: Map.delete(state.topics, topic),
        else: Map.put(state.topics, topic, new_subs)

    {:reply, :ok, %{state | topics: new_topics}}
  end

  def handle_call({:broadcast, topic, message}, _from, state) do
    subs = Map.get(state.topics, topic, MapSet.new())
    pids = MapSet.to_list(subs)

    start_time = System.monotonic_time()

    case pids do
      [] -> :ok
      pids -> Manifold.send(pids, message)
    end

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:crucible, :pubsub, :broadcast],
      %{duration: duration, subscriber_count: length(pids)},
      %{topic: topic}
    )

    {:reply, :ok, state}
  end

  def handle_call({:subscribers, topic}, _from, state) do
    subs = Map.get(state.topics, topic, MapSet.new())
    {:reply, MapSet.to_list(subs), state}
  end

  def handle_call(:stats, _from, state) do
    stats = Map.new(state.topics, fn {topic, subs} -> {topic, MapSet.size(subs)} end)
    {:reply, stats, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Remove pid from all topics
    new_topics =
      state.topics
      |> Enum.map(fn {topic, subs} -> {topic, MapSet.delete(subs, pid)} end)
      |> Enum.reject(fn {_topic, subs} -> MapSet.size(subs) == 0 end)
      |> Map.new()

    new_monitors = Map.delete(state.monitors, pid)

    {:noreply, %{state | topics: new_topics, monitors: new_monitors}}
  end
end
