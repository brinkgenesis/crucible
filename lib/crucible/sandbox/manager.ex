defmodule Crucible.Sandbox.Manager do
  @moduledoc """
  Manages a pool of pre-warmed sandbox containers for API workflow execution.

  Containers are acquired per-phase and released on completion. If Docker is
  unavailable (circuit breaker open), falls back to LocalProvider transparently.

  ## Configuration

      config :crucible, :sandbox,
        mode: :docker,        # :local (default) or :docker
        pool_size: 3,
        image: "node:22-alpine",
        policy_preset: :standard,
        network_allowlist: nil  # comma-separated host:port list, or nil
  """
  use GenServer
  require Logger

  alias Crucible.Sandbox.{Policy, DockerProvider, LocalProvider}
  alias Crucible.{ExternalCircuitBreaker, Events, FeatureFlags}

  @pool_refill_delay_ms 1_000

  # Explicit call timeout — status reads in-memory map, but may reflect Docker state
  # so 10s covers any brief contention without being as liberal as acquire (30s).
  @call_timeout_status 10_000

  # --- Client API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Acquire a sandbox for a run. Returns container ID."
  @spec acquire(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def acquire(run_id, opts \\ [], server \\ __MODULE__) do
    GenServer.call(server, {:acquire, run_id, opts}, 30_000)
  end

  @doc "Release a sandbox after phase completion."
  @spec release(String.t()) :: :ok
  def release(sandbox_id, server \\ __MODULE__) do
    GenServer.cast(server, {:release, sandbox_id})
  end

  @doc "Release all sandboxes for a given run."
  @spec release_for_run(String.t()) :: :ok
  def release_for_run(run_id, server \\ __MODULE__) do
    GenServer.cast(server, {:release_for_run, run_id})
  end

  @doc "Current pool and allocation status."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status, @call_timeout_status)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    config = sandbox_config()
    mode = Keyword.get(config, :mode, :local)

    state = %{
      mode: mode,
      provider: provider_for(mode),
      image: Keyword.get(config, :image, "node:22-alpine"),
      policy_preset: Keyword.get(config, :policy_preset, :standard),
      pool_size: Keyword.get(config, :pool_size, 3),
      pool: [],
      active: %{},
      run_map: %{}
    }

    enabled? = FeatureFlags.enabled?(:sandbox_enabled)

    case {enabled?, mode} do
      {true, :docker} ->
        Logger.info("Sandbox.Manager: starting with Docker provider, pool_size=#{state.pool_size}")
        send(self(), :warm_pool)

      {true, :local} ->
        Logger.warning(
          "Sandbox.Manager: sandbox_enabled=true but SANDBOX_MODE=local — " <>
            "no real container isolation. Set SANDBOX_MODE=docker for production workloads."
        )

      {false, _} ->
        Logger.info("Sandbox.Manager: disabled (sandbox_enabled=false)")
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, run_id, opts}, _from, state) do
    workspace_path = Keyword.get(opts, :workspace_path, "/tmp/sandbox-#{run_id}")
    policy = Policy.from_preset(state.policy_preset)

    case do_acquire(workspace_path, policy, state) do
      {:ok, sandbox_id, new_state} ->
        now = System.monotonic_time(:millisecond)

        new_state =
          new_state
          |> put_in([:active, sandbox_id], %{run_id: run_id, started_at: now})
          |> update_in([:run_map], &Map.update(&1, run_id, [sandbox_id], fn ids -> [sandbox_id | ids] end))

        # Audit + telemetry
        Events.broadcast_alert_event(:sandbox_started, %{
          sandbox_id: sandbox_id,
          run_id: run_id,
          mode: new_state.mode,
          policy: new_state.policy_preset
        })

        :telemetry.execute(
          [:infra, :sandbox, :acquired],
          %{count: 1, active: map_size(new_state.active), pool: length(new_state.pool)},
          %{run_id: run_id, sandbox_id: sandbox_id, mode: new_state.mode}
        )

        {:reply, {:ok, sandbox_id}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:status, _from, state) do
    reply = %{
      mode: state.mode,
      pool_available: length(state.pool),
      pool_target: state.pool_size,
      active_sandboxes: map_size(state.active),
      active_runs: map_size(state.run_map)
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:release, sandbox_id}, state) do
    state = do_release(sandbox_id, state)
    {:noreply, state}
  end

  def handle_cast({:release_for_run, run_id}, state) do
    sandbox_ids = Map.get(state.run_map, run_id, [])

    state =
      Enum.reduce(sandbox_ids, state, fn id, acc -> do_release(id, acc) end)
      |> update_in([:run_map], &Map.delete(&1, run_id))

    {:noreply, state}
  end

  @impl true
  def handle_info(:warm_pool, state) do
    deficit = state.pool_size - length(state.pool)

    if deficit > 0 and state.mode == :docker do
      state = warm_containers(deficit, state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:refill_pool, state) do
    send(self(), :warm_pool)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp do_acquire(workspace_path, policy, %{mode: :docker} = state) do
    case ExternalCircuitBreaker.check(:docker_daemon) do
      :ok ->
        case state.pool do
          [sandbox_id | rest] ->
            # Reuse pre-warmed container (already running, just need to track it)
            {:ok, sandbox_id, %{state | pool: rest}}

          [] ->
            # Pool exhausted — start on-demand
            Events.broadcast_alert_event(:sandbox_pool_exhausted, %{
              active: map_size(state.active),
              pool_target: state.pool_size
            })

            start_sandbox(workspace_path, policy, state)
        end

      {:blocked, reason} ->
        Logger.warning("Sandbox.Manager: Docker circuit open (#{reason}), falling back to local")
        start_sandbox_local(workspace_path, state)
    end
  end

  defp do_acquire(workspace_path, _policy, state) do
    start_sandbox_local(workspace_path, state)
  end

  defp start_sandbox(workspace_path, policy, state) do
    opts = %{
      workspace_path: workspace_path,
      policy: policy,
      image: state.image,
      labels: %{"managed-by" => "infra-sandbox-manager"}
    }

    case state.provider.start_sandbox(opts) do
      {:ok, sandbox_id} ->
        ExternalCircuitBreaker.record_success(:docker_daemon)
        {:ok, sandbox_id, state}

      {:error, reason} ->
        ExternalCircuitBreaker.record_failure(:docker_daemon)
        {:error, reason}
    end
  end

  defp start_sandbox_local(_workspace_path, state) do
    {:ok, sandbox_id} = LocalProvider.start_sandbox(%{})
    {:ok, sandbox_id, state}
  end

  defp do_release(sandbox_id, state) do
    if Map.has_key?(state.active, sandbox_id) do
      info = Map.get(state.active, sandbox_id)
      duration_ms = System.monotonic_time(:millisecond) - (info[:started_at] || 0)

      # Stop the container in a supervised fire-and-forget task
      provider = state.provider

      Task.Supervisor.start_child(Crucible.TaskSupervisor, fn ->
        provider.stop_sandbox(sandbox_id)
      end)

      state = update_in(state.active, &Map.delete(&1, sandbox_id))

      # Audit + telemetry
      Events.broadcast_alert_event(:sandbox_stopped, %{
        sandbox_id: sandbox_id,
        run_id: info[:run_id],
        duration_ms: duration_ms
      })

      :telemetry.execute(
        [:infra, :sandbox, :released],
        %{count: 1, duration_ms: duration_ms, active: map_size(state.active)},
        %{sandbox_id: sandbox_id, run_id: info[:run_id]}
      )

      # Schedule pool refill
      Process.send_after(self(), :refill_pool, @pool_refill_delay_ms)

      state
    else
      state
    end
  end

  defp warm_containers(count, state) do
    policy = Policy.from_preset(state.policy_preset)

    new_containers =
      1..count
      |> Enum.reduce([], fn _, acc ->
        opts = %{
          workspace_path: "/tmp/sandbox-warm",
          policy: policy,
          image: state.image,
          labels: %{"managed-by" => "infra-sandbox-manager", "warm" => "true"}
        }

        case state.provider.start_sandbox(opts) do
          {:ok, id} ->
            ExternalCircuitBreaker.record_success(:docker_daemon)
            [id | acc]

          {:error, reason} ->
            ExternalCircuitBreaker.record_failure(:docker_daemon)
            Logger.warning("Sandbox.Manager: failed to warm container: #{inspect(reason)}")
            acc
        end
      end)

    %{state | pool: state.pool ++ new_containers}
  end

  defp provider_for(:docker), do: DockerProvider
  defp provider_for(_), do: LocalProvider

  defp sandbox_config do
    Application.get_env(:crucible, :sandbox, [])
  end
end
