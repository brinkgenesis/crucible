defmodule Crucible.Tenant.Registry do
  @moduledoc """
  Maps tenant_id to its supervisor PID using an Elixir Registry.

  Provides fast O(1) lookups for tenant supervisor processes.
  """

  @registry __MODULE__

  @doc "Child spec for the supervision tree."
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: @registry)
  end

  @doc "Look up the supervisor PID for a tenant."
  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(tenant_id) do
    case Registry.lookup(@registry, tenant_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "Register the calling process as the supervisor for a tenant."
  @spec register(String.t()) :: {:ok, pid()} | {:error, {:already_registered, pid()}}
  def register(tenant_id) do
    Registry.register(@registry, tenant_id, nil)
  end

  @doc "Unregister the tenant entry for the calling process."
  @spec unregister(String.t()) :: :ok
  def unregister(tenant_id) do
    Registry.unregister(@registry, tenant_id)
  end

  @doc "Returns the registry name (for via tuples)."
  @spec registry_name() :: atom()
  def registry_name, do: @registry
end
