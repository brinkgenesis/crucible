defmodule Crucible.ExternalCircuitBreaker do
  @moduledoc """
  GenServer-backed circuit breaker for external HTTP services.
  Wraps the pure `Orchestrator.CircuitBreaker` state machine with per-service
  state keyed by atom (`:model_router`, `:api_server`, `:docker_daemon`, etc.).

  Uses GenServer instead of Agent to decouple state mutation from side effects
  (alert broadcasting). State is updated first, then side effects are triggered
  outside the state callback — a broadcast crash won't lose the state update.
  """
  use GenServer
  require Logger

  alias Crucible.Orchestrator.CircuitBreaker, as: CB

  # Explicit call timeout — in-memory state reads; pass explicitly for consistency.
  @call_timeout 5_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc """
  Checks if the circuit for `service` allows a request.
  Returns `:ok` or `{:blocked, reason}`.
  """
  @spec check(atom()) :: :ok | {:blocked, String.t()}
  def check(service) do
    GenServer.call(__MODULE__, {:check, service}, @call_timeout)
  end

  @doc "Records a successful call to `service`."
  @spec record_success(atom()) :: :ok
  def record_success(service) do
    GenServer.cast(__MODULE__, {:record_success, service})
  end

  @doc "Records a failed call to `service`."
  @spec record_failure(atom()) :: :ok
  def record_failure(service) do
    GenServer.cast(__MODULE__, {:record_failure, service})
  end

  @doc "Manually reset a circuit breaker for `service` to closed state."
  @spec reset(atom()) :: :ok
  def reset(service) do
    GenServer.cast(__MODULE__, {:reset, service})
  end

  @doc "Returns the current state of all circuit breakers."
  @spec status() :: %{atom() => CB.state()}
  def status do
    GenServer.call(__MODULE__, :status, @call_timeout)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:check, service}, _from, state) do
    cb = Map.get(state, service, CB.new())

    case CB.check(cb) do
      {:ok, cb} ->
        {:reply, :ok, Map.put(state, service, cb)}

      {:blocked, reason, cb} ->
        {:reply, {:blocked, reason}, Map.put(state, service, cb)}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:record_success, service}, state) do
    cb = Map.get(state, service, CB.new())
    {:noreply, Map.put(state, service, CB.record_success(cb))}
  end

  def handle_cast({:record_failure, service}, state) do
    cb_old = Map.get(state, service, CB.new())
    cb_new = CB.record_failure(cb_old)

    # State is updated FIRST, then side effects run outside the state mutation
    new_state = Map.put(state, service, cb_new)

    # Alert when circuit breaker transitions to :open
    if cb_new.state == :open and cb_old.state != :open do
      try do
        Crucible.Events.broadcast_alert_event(:circuit_breaker_open, %{
          service: service,
          failures: cb_new.consecutive_failures
        })
      rescue
        e ->
          Logger.warning(
            "ExternalCircuitBreaker: alert broadcast failed for #{service}: #{Exception.message(e)}"
          )
      end
    end

    {:noreply, new_state}
  end

  def handle_cast({:reset, service}, state) do
    {:noreply, Map.put(state, service, CB.new())}
  end
end
