defmodule Crucible.RollupCache do
  @moduledoc """
  Lightweight ETS cache for expensive dashboard rollups.
  """

  @table :infra_rollup_cache

  @spec fetch(term(), non_neg_integer(), (() -> term())) :: term()
  def fetch(key, ttl_ms, fun) when is_integer(ttl_ms) and ttl_ms >= 0 and is_function(fun, 0) do
    ensure_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        value

      _ ->
        value = fun.()
        :ets.insert(@table, {key, value, now + ttl_ms})
        value
    end
  rescue
    _ -> fun.()
  end

  @spec invalidate(term()) :: :ok
  def invalidate(key) do
    ensure_table()
    :ets.delete(@table, key)
    :ok
  rescue
    _ -> :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :set, :public, read_concurrency: true, write_concurrency: true])
        :ok

      _tid ->
        :ok
    end
  rescue
    ArgumentError ->
      # Another process created it concurrently.
      :ok
  end
end
