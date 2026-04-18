defmodule Crucible.Router.QuotaTracker do
  @moduledoc """
  Tracks provider-level quota health so the router can skip exhausted
  providers and the Elixir SDK can downshift models.

  State is kept in an ETS table; updates come from:
    * Explicit `record_success/1` / `record_exhausted/2` calls from the router.
    * Rate-limit events emitted by `Crucible.ElixirSdk.Client` (when the
      client sees a 429 or `rate_limit_event` with `status != "allowed"`).

  A provider is considered exhausted until `resets_at` (a monotonic
  millisecond timestamp). The tracker is non-authoritative — it's a hint,
  not a gate.
  """

  use GenServer

  @table :crucible_router_quota
  @ttl_ms_default 60_000

  # ── Public API ─────────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Returns true if the provider is currently marked exhausted."
  @spec provider_exhausted?(String.t()) :: boolean()
  def provider_exhausted?(provider) when is_binary(provider) do
    case safe_lookup(provider) do
      nil -> false
      resets_at -> System.monotonic_time(:millisecond) < resets_at
    end
  end

  @doc "Returns true if the given model's provider is currently exhausted."
  @spec is_model_exhausted?(String.t()) :: boolean()
  def is_model_exhausted?(model_id) when is_binary(model_id) do
    case Crucible.Router.CostTable.get(model_id) do
      %{provider: p} -> provider_exhausted?(p)
      _ -> false
    end
  end

  @doc "Mark a provider as exhausted for the given ms (default 60s)."
  @spec record_exhausted(String.t(), pos_integer()) :: :ok
  def record_exhausted(provider, ttl_ms \\ @ttl_ms_default) when is_binary(provider) do
    ensure_running()
    GenServer.cast(__MODULE__, {:record_exhausted, provider, ttl_ms})
  end

  @doc "Clear the exhausted mark for a provider (rate limit recovered)."
  @spec record_success(String.t()) :: :ok
  def record_success(provider) when is_binary(provider) do
    ensure_running()
    GenServer.cast(__MODULE__, {:record_success, provider})
  end

  @doc "Dump the current quota state for inspection."
  @spec snapshot() :: %{String.t() => %{exhausted_for_ms: integer()}}
  def snapshot do
    ensure_running()
    now = System.monotonic_time(:millisecond)

    :ets.tab2list(@table)
    |> Enum.into(%{}, fn {provider, resets_at} ->
      {provider, %{exhausted_for_ms: max(resets_at - now, 0)}}
    end)
  end

  # ── GenServer ─────────────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, :no_state}
  end

  @impl true
  def handle_cast({:record_exhausted, provider, ttl_ms}, state) do
    resets_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {provider, resets_at})
    {:noreply, state}
  end

  def handle_cast({:record_success, provider}, state) do
    :ets.delete(@table, provider)
    {:noreply, state}
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp safe_lookup(provider) do
    if :ets.whereis(@table) != :undefined do
      case :ets.lookup(@table, provider) do
        [{^provider, resets_at}] -> resets_at
        _ -> nil
      end
    end
  end

  defp ensure_running do
    case Process.whereis(__MODULE__) do
      nil -> start_link([])
      _pid -> :ok
    end
  end
end
