defmodule Crucible.Cluster.DistributedRegistryTest do
  use ExUnit.Case, async: false

  alias Crucible.Cluster.DistributedRegistry

  # Tests that require Horde.Registry running — start it in setup
  describe "register/2 and lookup/1" do
    setup do
      ensure_registry_started()
    end

    test "registers and looks up a process by name" do
      name = {:run, "test-1"}

      assert {:ok, _pid} = DistributedRegistry.register(name)
      assert [{pid, nil}] = lookup_eventually(name)
      assert pid == self()
    end

    test "registers with a custom value" do
      assert {:ok, _pid} = DistributedRegistry.register({:run, "val-1"}, %{node: node()})
      # Allow Horde CRDT to propagate before lookup
      Process.sleep(50)
      assert [{pid, %{node: _}}] = DistributedRegistry.lookup({:run, "val-1"})
      assert pid == self()
    end

    test "returns empty list for unregistered name" do
      assert [] = DistributedRegistry.lookup({:run, "nonexistent"})
    end

    test "prevents duplicate registration from different processes" do
      name = {:run, "dup-#{System.unique_integer([:positive])}"}
      assert {:ok, _pid} = DistributedRegistry.register(name)

      task =
        Task.async(fn ->
          DistributedRegistry.register(name)
        end)

      result = Task.await(task)
      assert {:error, {:already_registered, _}} = result
    end
  end

  describe "unregister/1" do
    setup do
      ensure_registry_started()
    end

    test "removes a registered name" do
      assert {:ok, _pid} = DistributedRegistry.register({:run, "unreg-1"})
      assert :ok = DistributedRegistry.unregister({:run, "unreg-1"})
      assert [] = DistributedRegistry.lookup({:run, "unreg-1"})
    end
  end

  describe "list_all/0" do
    setup do
      ensure_registry_started()
    end

    test "lists all registered processes" do
      name = {:run, "list-#{System.unique_integer([:positive])}"}
      assert {:ok, _pid} = DistributedRegistry.register(name, :active)
      # Allow Horde CRDT to propagate before querying via select
      Process.sleep(50)
      entries = DistributedRegistry.list_all()
      assert Enum.any?(entries, fn {n, _pid, _val} -> n == name end)
    end
  end

  describe "via/2" do
    test "returns a via-tuple for GenServer registration" do
      via = DistributedRegistry.via({:run, "via-1"})
      assert {:via, Horde.Registry, {DistributedRegistry, {:run, "via-1"}, nil}} = via
    end

    test "via-tuple includes custom value" do
      via = DistributedRegistry.via({:run, "via-2"}, :metadata)
      assert {:via, Horde.Registry, {DistributedRegistry, {:run, "via-2"}, :metadata}} = via
    end
  end

  describe "process cleanup on death" do
    setup do
      ensure_registry_started()
    end

    test "automatically unregisters when the owning process exits" do
      name = {:run, "cleanup-1"}

      task =
        Task.async(fn ->
          {:ok, _} = DistributedRegistry.register(name)
          :registered
        end)

      assert :registered = Task.await(task)

      Process.sleep(100)
      assert [] = DistributedRegistry.lookup(name)
    end

    test "does not affect other registrations when one process dies" do
      survivor_name = {:run, "survivor-#{System.unique_integer([:positive])}"}
      doomed_name = {:run, "doomed-#{System.unique_integer([:positive])}"}

      {:ok, _} = DistributedRegistry.register(survivor_name)

      task =
        Task.async(fn ->
          {:ok, _} = DistributedRegistry.register(doomed_name)
          :ok
        end)

      Task.await(task)
      Process.sleep(100)

      assert [{_pid, _}] = DistributedRegistry.lookup(survivor_name)
      assert [] = DistributedRegistry.lookup(doomed_name)
    end
  end

  describe "node affinity selection" do
    test "selects local node when it has capacity" do
      local = node()
      nodes_with_load = [{local, 2}, {:"peer@127.0.0.1", 5}]

      selected = select_least_loaded(nodes_with_load)
      assert selected == local
    end

    test "selects least-loaded node" do
      nodes_with_load = [
        {:"node1@127.0.0.1", 10},
        {:"node2@127.0.0.1", 3},
        {:"node3@127.0.0.1", 7}
      ]

      selected = select_least_loaded(nodes_with_load)
      assert selected == :"node2@127.0.0.1"
    end

    test "breaks ties deterministically" do
      nodes_with_load = [
        {:"node_b@127.0.0.1", 5},
        {:"node_a@127.0.0.1", 5}
      ]

      selected = select_least_loaded(nodes_with_load)
      assert selected == :"node_a@127.0.0.1"
    end
  end

  describe "work stealing logic" do
    test "idle node identifies stealable work from busy node" do
      node_loads = %{
        :"idle@127.0.0.1" => 0,
        :"busy@127.0.0.1" => 6
      }

      steal_threshold = 3
      stealable = find_stealable_work(node_loads, :"idle@127.0.0.1", steal_threshold)

      assert stealable == :"busy@127.0.0.1"
    end

    test "no stealing when load is balanced" do
      node_loads = %{
        :"a@127.0.0.1" => 3,
        :"b@127.0.0.1" => 4
      }

      steal_threshold = 3
      stealable = find_stealable_work(node_loads, :"a@127.0.0.1", steal_threshold)

      assert stealable == nil
    end

    test "steals from the most loaded node" do
      node_loads = %{
        :"idle@127.0.0.1" => 0,
        :"medium@127.0.0.1" => 4,
        :"heavy@127.0.0.1" => 10
      }

      steal_threshold = 3
      stealable = find_stealable_work(node_loads, :"idle@127.0.0.1", steal_threshold)

      assert stealable == :"heavy@127.0.0.1"
    end
  end

  # --- Helpers ---

  defp ensure_registry_started do
    if Process.whereis(Crucible.Cluster.DistributedRegistry) == nil do
      start_supervised!({DistributedRegistry, []})
    end

    # Horde CRDT needs time to initialize under heavy parallel test load
    Process.sleep(100)
    :ok
  end

  defp lookup_eventually(name, attempts \\ 10)

  defp lookup_eventually(name, 1), do: DistributedRegistry.lookup(name)

  defp lookup_eventually(name, attempts) do
    case DistributedRegistry.lookup(name) do
      [] ->
        Process.sleep(25)
        lookup_eventually(name, attempts - 1)

      entries ->
        entries
    end
  end

  defp select_least_loaded(nodes_with_load) do
    nodes_with_load
    |> Enum.sort_by(fn {node, load} -> {load, node} end)
    |> hd()
    |> elem(0)
  end

  defp find_stealable_work(node_loads, idle_node, threshold) do
    idle_load = Map.get(node_loads, idle_node, 0)

    node_loads
    |> Enum.reject(fn {n, _} -> n == idle_node end)
    |> Enum.filter(fn {_n, load} -> load - idle_load > threshold end)
    |> Enum.sort_by(fn {_n, load} -> load end, :desc)
    |> case do
      [{node, _load} | _] -> node
      [] -> nil
    end
  end
end
