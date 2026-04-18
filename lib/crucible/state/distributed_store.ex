defmodule Crucible.State.DistributedStore do
  @moduledoc """
  Mnesia-backed distributed store for workflow state.
  Replaces file-based persistence with disc_copies tables that
  replicate across the cluster automatically.

  All writes use Mnesia transactions for atomicity.
  Conflict resolution: last-write-wins via `updated_at` timestamps.
  """

  use GenServer
  require Logger

  alias Crucible.State.Schema

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Runs

  @spec put_run(String.t(), map()) :: :ok | {:error, term()}
  def put_run(id, attrs) do
    transact_write(:distributed_runs, id, attrs)
  end

  @spec get_run(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_run(id) do
    transact_read(:distributed_runs, id)
  end

  @spec list_runs() :: [map()]
  def list_runs do
    transact_list(:distributed_runs)
  end

  @spec delete_run(String.t()) :: :ok
  def delete_run(id) do
    transact_delete(:distributed_runs, id)
  end

  # Phases

  @spec put_phase(String.t(), map()) :: :ok | {:error, term()}
  def put_phase(id, attrs) do
    transact_write(:distributed_phases, id, attrs)
  end

  @spec get_phase(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_phase(id) do
    transact_read(:distributed_phases, id)
  end

  @spec list_phases() :: [map()]
  def list_phases do
    transact_list(:distributed_phases)
  end

  @spec delete_phase(String.t()) :: :ok
  def delete_phase(id) do
    transact_delete(:distributed_phases, id)
  end

  # Results

  @spec put_result(String.t(), map()) :: :ok | {:error, term()}
  def put_result(id, attrs) do
    transact_write(:distributed_results, id, attrs)
  end

  @spec get_result(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_result(id) do
    transact_read(:distributed_results, id)
  end

  @spec list_results() :: [map()]
  def list_results do
    transact_list(:distributed_results)
  end

  @spec delete_result(String.t()) :: :ok
  def delete_result(id) do
    transact_delete(:distributed_results, id)
  end

  # Circuit Breakers

  @spec put_circuit_breaker(String.t(), map()) :: :ok | {:error, term()}
  def put_circuit_breaker(workflow_name, attrs) do
    transact_write(:distributed_circuit_breakers, workflow_name, attrs)
  end

  @spec get_circuit_breaker(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_circuit_breaker(workflow_name) do
    transact_read(:distributed_circuit_breakers, workflow_name)
  end

  @spec list_circuit_breakers() :: [map()]
  def list_circuit_breakers do
    transact_list(:distributed_circuit_breakers)
  end

  @spec delete_circuit_breaker(String.t()) :: :ok
  def delete_circuit_breaker(workflow_name) do
    transact_delete(:distributed_circuit_breakers, workflow_name)
  end

  # Queries

  @doc "Find all runs with status :pending or :running — replaces file-based scan."
  @spec scan_pending_runs() :: [map()]
  def scan_pending_runs do
    match_head = {
      :distributed_runs,
      :"$1",
      :_,
      :"$2",
      :_,
      :_,
      :_,
      :_,
      :_,
      :_,
      :_,
      :_,
      :_,
      :_,
      :_,
      :_,
      :_
    }

    guard_pending = {:==, :"$2", :pending}
    guard_running = {:==, :"$2", :running}
    guard = {:orelse, guard_pending, guard_running}
    result = [:"$$"]

    case :mnesia.transaction(fn ->
           :mnesia.select(:distributed_runs, [{match_head, [guard], result}])
         end) do
      {:atomic, rows} ->
        Enum.map(rows, fn fields ->
          record_to_map(:distributed_runs, List.to_tuple([:distributed_runs | fields]))
        end)

      {:aborted, reason} ->
        Logger.debug("DistributedStore: scan_pending_runs unavailable: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    # Ensure Mnesia directory and schema exist before starting
    ensure_mnesia_started()

    case Schema.create_tables() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("DistributedStore: table creation failed: #{inspect(reason)}")
    end

    case Schema.wait_for_tables(15_000) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("DistributedStore: wait_for_tables: #{inspect(reason)}")
    end

    # Subscribe to system events for node join handling
    :mnesia.subscribe(:system)

    Logger.info("DistributedStore: initialized on #{node()}")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:mnesia_system_event, {:mnesia_up, node}}, state) do
    Logger.info("DistributedStore: node joined — #{node}, replicating tables")
    Schema.ensure_schema(node)
    {:noreply, state}
  end

  @impl true
  def handle_info({:mnesia_system_event, {:mnesia_down, node}}, state) do
    Logger.info("DistributedStore: node left — #{node}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:mnesia_system_event, _event}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private Helpers ---

  defp ensure_mnesia_started do
    # Create schema directory if needed (must happen before :mnesia.start)
    :mnesia.create_schema([node()])
    # start is idempotent — returns :ok if already started
    :mnesia.start()
  end

  defp transact_write(table, key, attrs) do
    now = DateTime.utc_now()
    attr_names = Schema.attributes(table)
    current_version = Map.get(attrs, :version, 0)

    # Build record tuple: {table, key, field2, field3, ...}
    values =
      Enum.map(attr_names, fn
        name when name == hd(attr_names) -> key
        :updated_at -> now
        :version -> current_version + 1
        name -> Map.get(attrs, name)
      end)

    record = List.to_tuple([table | values])

    case :mnesia.transaction(fn ->
           # Last-write-wins: check existing version
           case :mnesia.read(table, key) do
             [existing] ->
               updated_at_idx = Enum.find_index(attr_names, &(&1 == :updated_at)) + 1
               existing_updated = elem(existing, updated_at_idx)

               if existing_updated != nil and DateTime.compare(existing_updated, now) == :gt do
                 # Existing record is newer — skip write
                 :ok
               else
                 :mnesia.write(record)
               end

             [] ->
               :mnesia.write(record)
           end
         end) do
      {:atomic, _} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp transact_read(table, key) do
    case :mnesia.transaction(fn -> :mnesia.read(table, key) end) do
      {:atomic, [record]} -> {:ok, record_to_map(table, record)}
      {:atomic, []} -> {:error, :not_found}
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp transact_list(table) do
    case :mnesia.transaction(fn ->
           :mnesia.foldl(fn record, acc -> [record | acc] end, [], table)
         end) do
      {:atomic, records} ->
        Enum.map(records, &record_to_map(table, &1))

      {:aborted, reason} ->
        Logger.error("DistributedStore: list #{table} failed: #{inspect(reason)}")
        []
    end
  end

  defp transact_delete(table, key) do
    case :mnesia.transaction(fn -> :mnesia.delete({table, key}) end) do
      {:atomic, :ok} ->
        :ok

      {:aborted, reason} ->
        Logger.error("DistributedStore: delete from #{table} failed: #{inspect(reason)}")
        :ok
    end
  end

  defp record_to_map(table, record) do
    attr_names = Schema.attributes(table)
    # record is {table, val1, val2, ...}
    values = Tuple.to_list(record) |> tl()
    Enum.zip(attr_names, values) |> Map.new()
  end
end
