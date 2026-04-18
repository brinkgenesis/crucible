defmodule Crucible.Cluster.DistributedRegistry do
  @moduledoc """
  Cluster-wide process registry backed by Horde.Registry.

  Provides global process registration and lookup across all connected nodes.
  Handles netsplits gracefully via Horde's CRDT-based conflict resolution.
  """

  @registry __MODULE__

  def start_link(opts \\ []) do
    config =
      Keyword.merge(
        [keys: :unique, name: @registry, members: :auto],
        opts
      )

    Horde.Registry.start_link(config)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Registers the calling process under the given `name`.
  Returns `{:ok, pid}` or `{:error, {:already_registered, pid}}`.
  """
  def register(name, value \\ nil) do
    Horde.Registry.register(@registry, name, value)
  end

  @doc """
  Looks up a process by `name` across the cluster.
  Returns `[{pid, value}]` or `[]` if not found.
  """
  def lookup(name) do
    Horde.Registry.lookup(@registry, name)
  end

  @doc """
  Returns all registered `{name, pid, value}` tuples.
  """
  def list_all do
    Horde.Registry.select(@registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
  end

  @doc """
  Unregisters the given `name` from the registry.
  """
  def unregister(name) do
    Horde.Registry.unregister(@registry, name)
  end

  @doc """
  Returns a via-tuple for use in GenServer.start_link name registration.

  ## Example

      GenServer.start_link(MyServer, args, name: DistributedRegistry.via({:run, run_id}))
  """
  def via(name, value \\ nil) do
    {:via, Horde.Registry, {@registry, name, value}}
  end
end
