defmodule Crucible.FeatureFlags do
  @moduledoc """
  Runtime feature flags backed by ETS. Flags can be toggled without restarting.

  Usage:
    FeatureFlags.enabled?(:new_dispatch_algo)
    FeatureFlags.enable(:new_dispatch_algo)
    FeatureFlags.disable(:new_dispatch_algo)
    FeatureFlags.set(:new_dispatch_algo, true)
  """
  use GenServer
  require Logger

  @table :feature_flags

  # Explicit call timeout — ETS write serialized through GenServer; fast but explicit.
  @call_timeout 5_000

  # Default flags — override via config or runtime API
  @defaults [
    new_dispatch_algo: false,
    strict_content_type: false,
    bulkhead_enabled: true,
    idempotency_check: true,
    structured_log_context: true,
    sandbox_enabled: true,
    sdk_port_adapter: false,
    tmux_port_adapter: false
  ]

  # Client API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec enabled?(atom()) :: boolean()
  def enabled?(flag) do
    case :ets.lookup(@table, flag) do
      [{_, value}] -> value
      [] -> false
    end
  end

  @spec enable(atom()) :: :ok
  def enable(flag), do: set(flag, true)

  @spec disable(atom()) :: :ok
  def disable(flag), do: set(flag, false)

  @spec set(atom(), boolean()) :: :ok
  def set(flag, value) when is_boolean(value) do
    GenServer.call(__MODULE__, {:set, flag, value}, @call_timeout)
  end

  @spec all() :: [{atom(), boolean()}]
  def all() do
    :ets.tab2list(@table)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

    config_flags = Application.get_env(:crucible, :feature_flags, [])

    Enum.each(@defaults, fn {flag, default} ->
      value = Keyword.get(config_flags, flag, default)
      :ets.insert(@table, {flag, value})
    end)

    {:ok, %{}}
  end

  @impl true
  def handle_call({:set, flag, value}, _from, state) do
    :ets.insert(@table, {flag, value})
    Logger.info("FeatureFlags: #{flag} set to #{value}")
    {:reply, :ok, state}
  end
end
