defmodule Crucible.State.Schema do
  @moduledoc """
  Mnesia table definitions for distributed state persistence.
  Replaces file-based state with disc_copies tables that replicate
  across cluster nodes.

  Tables:
  - :distributed_runs — workflow run manifests
  - :distributed_phases — phase records within runs
  - :distributed_results — phase execution results
  - :distributed_circuit_breakers — per-workflow circuit breaker state
  """

  require Logger

  @tables [
    :distributed_runs,
    :distributed_phases,
    :distributed_results,
    :distributed_circuit_breakers
  ]

  @doc "All managed table names."
  @spec tables() :: [atom()]
  def tables, do: @tables

  @doc """
  Table attributes for each Mnesia table.
  Every table includes `:updated_at` (UTC timestamp) and `:version` (vector clock)
  for conflict resolution.
  """
  @spec attributes(atom()) :: [atom()]
  def attributes(:distributed_runs) do
    [
      :id,
      :workflow_type,
      :status,
      :phases,
      :workspace_path,
      :branch,
      :plan_note,
      :plan_summary,
      :budget_usd,
      :client_id,
      :started_at,
      :completed_at,
      :error,
      :data,
      :updated_at,
      :version
    ]
  end

  def attributes(:distributed_phases) do
    [
      :id,
      :run_id,
      :name,
      :type,
      :status,
      :prompt,
      :phase_index,
      :data,
      :updated_at,
      :version
    ]
  end

  def attributes(:distributed_results) do
    [
      :id,
      :run_id,
      :phase_id,
      :exit_code,
      :output,
      :data,
      :updated_at,
      :version
    ]
  end

  def attributes(:distributed_circuit_breakers) do
    [
      :workflow_name,
      :state,
      :consecutive_failures,
      :opened_at,
      :cooldown_ms,
      :last_failed_at,
      :updated_at,
      :version
    ]
  end

  @doc """
  Create all Mnesia tables with disc_copies on the current node.
  Safe to call multiple times — skips tables that already exist.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec create_tables() :: :ok | {:error, term()}
  def create_tables do
    node = node()

    results =
      Enum.map(@tables, fn table ->
        opts = [
          attributes: attributes(table),
          disc_copies: [node],
          type: :set
        ]

        case :mnesia.create_table(table, opts) do
          {:atomic, :ok} ->
            Logger.info("Mnesia: created table #{table}")
            :ok

          {:aborted, {:already_exists, ^table}} ->
            :ok

          {:aborted, reason} ->
            Logger.error("Mnesia: failed to create #{table}: #{inspect(reason)}")
            {:error, {table, reason}}
        end
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> :ok
      error -> error
    end
  end

  @doc """
  Ensure Mnesia schema and table replicas exist on the given node.
  Called when a new node joins the cluster to replicate all tables.
  """
  @spec ensure_schema(node()) :: :ok | {:error, term()}
  def ensure_schema(target_node) do
    # Add schema replica first
    case :mnesia.change_table_copy_type(:schema, target_node, :disc_copies) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, :schema, ^target_node, :disc_copies}} -> :ok
      {:aborted, reason} -> Logger.warning("Mnesia: schema copy failed: #{inspect(reason)}")
    end

    # Add disc_copies for each table on the target node
    results =
      Enum.map(@tables, fn table ->
        case :mnesia.add_table_copy(table, target_node, :disc_copies) do
          {:atomic, :ok} ->
            Logger.info("Mnesia: replicated #{table} to #{target_node}")
            :ok

          {:aborted, {:already_exists, ^table, ^target_node}} ->
            :ok

          {:aborted, reason} ->
            Logger.error(
              "Mnesia: failed to replicate #{table} to #{target_node}: #{inspect(reason)}"
            )

            {:error, {table, reason}}
        end
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> :ok
      error -> error
    end
  end

  @doc """
  Wait for all tables to be available (up to timeout_ms).
  Should be called after Mnesia starts and tables are created.
  """
  @spec wait_for_tables(non_neg_integer()) :: :ok | {:error, term()}
  def wait_for_tables(timeout_ms \\ 30_000) do
    case :mnesia.wait_for_tables(@tables, timeout_ms) do
      :ok -> :ok
      {:timeout, tables} -> {:error, {:timeout, tables}}
      {:error, reason} -> {:error, reason}
    end
  end
end
