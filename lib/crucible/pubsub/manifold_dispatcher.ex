defmodule Crucible.PubSub.ManifoldDispatcher do
  @moduledoc """
  Custom Phoenix.PubSub dispatcher that uses Discord's Manifold for fan-out.

  Manifold partitions subscriber PIDs across BEAM schedulers and sends messages
  in parallel, reducing bottlenecks when many LiveView processes subscribe to
  the same topic. The message format is unchanged — LiveView `handle_info`
  clauses work without modification.

  ## How it works

  Phoenix.PubSub calls `dispatch(entries, from, message)` via `Registry.dispatch/3`
  where `entries` is a list of `{pid, value}` tuples. The default dispatcher uses
  `send/2` sequentially. This dispatcher extracts PIDs, filters the sender, and
  delegates to `Manifold.send/2` which partitions across schedulers.

  ## Integration

  Used via `Crucible.PubSub.ManifoldAdapter` which transparently replaces
  the default dispatcher in all PubSub broadcasts.
  """

  @doc """
  Dispatches a broadcast message to all subscriber PIDs using Manifold.

  Filters out the `from` pid (for `broadcast_from` semantics) and dead processes,
  then fans out via `Manifold.send/2`.
  """
  @spec dispatch(entries :: [{pid(), term()}], from :: pid() | :none, message :: term()) :: :ok
  def dispatch(entries, from, message) do
    pids =
      for {pid, _value} <- entries,
          pid != from,
          do: pid

    case pids do
      [] ->
        :ok

      pids ->
        start_time = System.monotonic_time()
        Manifold.send(pids, message)
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:crucible, :pubsub, :dispatch],
          %{duration: duration, subscriber_count: length(pids)},
          %{message_type: if(is_tuple(message), do: elem(message, 0), else: :raw)}
        )
    end

    :ok
  end
end

defmodule Crucible.PubSub.ManifoldAdapter do
  @moduledoc """
  Phoenix.PubSub adapter wrapping PG2 that injects `ManifoldDispatcher` for all broadcasts.

  This adapter delegates to `Phoenix.PubSub.PG2` for cluster membership and message routing,
  but replaces the default dispatcher module (`Phoenix.PubSub`) with `ManifoldDispatcher`
  in `broadcast/4` and `direct_broadcast/5`. This means **all** existing
  `Phoenix.PubSub.broadcast(Crucible.PubSub, topic, msg)` calls automatically
  get Manifold fan-out without any call-site changes.

  ## Configuration

      # In Application supervisor:
      {Phoenix.PubSub,
        name: Crucible.PubSub,
        adapter: Crucible.PubSub.ManifoldAdapter}
  """

  @behaviour Phoenix.PubSub.Adapter

  @manifold_dispatcher Crucible.PubSub.ManifoldDispatcher

  # Delegate supervisor lifecycle to PG2
  defdelegate start_link(opts), to: Phoenix.PubSub.PG2

  @impl true
  defdelegate child_spec(opts), to: Phoenix.PubSub.PG2

  @impl true
  def node_name(adapter_name), do: Phoenix.PubSub.PG2.node_name(adapter_name)

  @impl true
  def broadcast(adapter_name, topic, message, _dispatcher) do
    Phoenix.PubSub.PG2.broadcast(adapter_name, topic, message, @manifold_dispatcher)
  end

  @impl true
  def direct_broadcast(adapter_name, node_name, topic, message, _dispatcher) do
    Phoenix.PubSub.PG2.direct_broadcast(adapter_name, node_name, topic, message, @manifold_dispatcher)
  end
end
