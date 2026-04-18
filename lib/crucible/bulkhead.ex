defmodule Crucible.Bulkhead do
  @moduledoc """
  Per-tenant bulkhead to prevent one tenant from exhausting shared resources.
  Uses ETS counters for lock-free concurrency tracking.
  """
  use GenServer

  @table :bulkhead_counts
  @default_limit 5

  # Client API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec acquire(String.t()) :: :ok | {:error, :bulkhead_full}
  def acquire(tenant_id) do
    limit = tenant_limit(tenant_id)
    # Cap at limit+1 so we can distinguish "at limit" from "over limit"
    count = :ets.update_counter(@table, tenant_id, {2, 1, limit + 1, limit + 1}, {tenant_id, 0})

    if count <= limit do
      :ok
    else
      # Over limit — roll back the increment
      :ets.update_counter(@table, tenant_id, {2, -1, 0, 0}, {tenant_id, 0})
      {:error, :bulkhead_full}
    end
  end

  @spec release(String.t()) :: :ok
  def release(tenant_id) do
    :ets.update_counter(@table, tenant_id, {2, -1, 0, 0}, {tenant_id, 0})
    :ok
  end

  @spec current(String.t()) :: non_neg_integer()
  def current(tenant_id) do
    case :ets.lookup(@table, tenant_id) do
      [{_, count}] -> count
      [] -> 0
    end
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      write_concurrency: true,
      read_concurrency: true
    ])

    {:ok, %{}}
  end

  # Private helpers

  defp tenant_limit(tenant_id) do
    Application.get_env(:crucible, :bulkhead_limits, %{})
    |> Map.get("tenant_#{tenant_id}", @default_limit)
  end
end
