defmodule Crucible.BudgetTracker do
  @moduledoc """
  GenServer for 3-tier cost control, backed by ETS for fast concurrent reads.
  Reads cost-events.jsonl on startup and receives new events via cast.

  Supports per-tenant instances: when started with `tenant_id`, registers via
  the TenantRegistry and scopes all ETS keys under that tenant. The global
  (singleton) instance remains the default for backward compatibility.

  Tracks costs at three levels:
  - **Daily** — `{date_string, total}` keyed by ISO-8601 date
  - **Per-agent** — `{{:agent, agent_id}, total}` keyed by agent ID
  - **Per-task** — `{{:task, task_id}, total}` keyed by task ID

  Per-tenant instances prefix all ETS keys with `{:tenant, tenant_id, ...}`
  so one tenant's costs never collide with another's.
  """
  use GenServer

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  @refresh_interval 10_000
  @table :budget_costs

  @type dashboard_status :: %{
          daily_spent: float(),
          daily_limit: float(),
          daily_remaining: float(),
          is_over_budget: boolean()
        }

  # --- Client API ---

  def start_link(opts \\ []) do
    case Keyword.get(opts, :tenant_id) do
      nil ->
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)

      tenant_id ->
        name = Crucible.Tenant.Subtree.via(tenant_id, :budget_tracker)
        GenServer.start_link(__MODULE__, Keyword.put(opts, :tenant_id, tenant_id), name: name)
    end
  end

  @doc "Returns today's budget status (global)."
  @spec daily_status() :: %{spent: float(), remaining: float(), exceeded?: boolean()}
  def daily_status do
    daily_status(nil)
  end

  @doc "Returns today's budget status for a specific tenant (or global if nil)."
  @spec daily_status(String.t() | nil) :: %{
          spent: float(),
          remaining: float(),
          exceeded?: boolean()
        }
  def daily_status(tenant_id) do
    today = Date.utc_today() |> Date.to_iso8601()
    key = ets_key(tenant_id, today)
    costs = read_cost(key)

    limit =
      Application.get_env(:crucible, :orchestrator, [])
      |> Keyword.get(:daily_budget_usd, 100.0)

    %{spent: costs, remaining: limit - costs, exceeded?: costs >= limit}
  end

  @doc "Returns per-agent budget status (global)."
  @spec agent_status(String.t()) :: %{spent: float(), remaining: float(), exceeded?: boolean()}
  def agent_status(agent_id) do
    agent_status(nil, agent_id)
  end

  @doc "Returns per-agent budget status for a specific tenant."
  @spec agent_status(String.t() | nil, String.t()) :: %{
          spent: float(),
          remaining: float(),
          exceeded?: boolean()
        }
  def agent_status(tenant_id, agent_id) do
    key = ets_key(tenant_id, {:agent, agent_id})
    cost = read_cost(key)

    limit =
      Application.get_env(:crucible, :orchestrator, [])
      |> Keyword.get(:agent_budget_usd, 10.0)

    %{spent: cost, remaining: limit - cost, exceeded?: cost >= limit}
  end

  @doc "Returns per-task budget status (global)."
  @spec task_status(String.t()) :: %{spent: float(), remaining: float(), exceeded?: boolean()}
  def task_status(task_id) do
    task_status(nil, task_id)
  end

  @doc "Returns per-task budget status for a specific tenant."
  @spec task_status(String.t() | nil, String.t()) :: %{
          spent: float(),
          remaining: float(),
          exceeded?: boolean()
        }
  def task_status(tenant_id, task_id) do
    key = ets_key(tenant_id, {:task, task_id})
    cost = read_cost(key)

    limit =
      Application.get_env(:crucible, :orchestrator, [])
      |> Keyword.get(:task_budget_usd, 50.0)

    %{spent: cost, remaining: limit - cost, exceeded?: cost >= limit}
  end

  @doc "Returns budget status in dashboard-friendly format."
  @spec status() :: dashboard_status()
  def status do
    ds = daily_status()

    %{
      daily_spent: ds.spent,
      daily_limit: ds.spent + ds.remaining,
      daily_remaining: ds.remaining,
      is_over_budget: ds.exceeded?
    }
  end

  @doc "Returns recent cost events (stub — returns from ETS daily totals)."
  @spec recent_events(non_neg_integer()) :: [map()]
  def recent_events(limit \\ 50) do
    GenServer.call(__MODULE__, {:recent_events, limit})
  end

  @doc "Returns daily spend history for N days."
  @spec daily_history(non_neg_integer()) :: [map()]
  def daily_history(days \\ 7) do
    today = Date.utc_today()

    Enum.map(0..(days - 1), fn offset ->
      date = Date.add(today, -offset) |> Date.to_iso8601()
      %{date: date, cost: read_cost(date)}
    end)
    |> Enum.reverse()
  end

  @doc "Records a cost event (global). Optionally tracks per-task costs via `task_id` option."
  @spec record_cost(String.t(), float(), keyword()) :: :ok
  def record_cost(agent_id, amount, opts \\ []) do
    GenServer.cast(__MODULE__, {:record_cost, agent_id, amount, opts})
  end

  @doc "Records a cost event for a specific tenant's BudgetTracker instance."
  @spec record_tenant_cost(String.t(), String.t(), float(), keyword()) :: :ok
  def record_tenant_cost(tenant_id, agent_id, amount, opts \\ []) do
    name = Crucible.Tenant.Subtree.via(tenant_id, :budget_tracker)
    GenServer.cast(name, {:record_cost, agent_id, amount, opts})
  end

  @doc "Checks all budget tiers. Returns :ok or {:exceeded, tier, status}."
  @spec budget_check(String.t(), keyword()) :: :ok | {:exceeded, atom(), map()}
  def budget_check(agent_id, opts \\ []) do
    Tracer.with_span "orchestrator.budget.check" do
      Tracer.set_attributes([{"agent.id", agent_id}])

      tenant_id = Keyword.get(opts, :tenant_id)

      ds = daily_status(tenant_id)
      if ds.exceeded?, do: throw({:exceeded, :daily, ds})

      as = agent_status(tenant_id, agent_id)
      if as.exceeded?, do: throw({:exceeded, :agent, as})

      case Keyword.get(opts, :task_id) do
        nil ->
          :ok

        task_id ->
          ts = task_status(tenant_id, task_id)
          if ts.exceeded?, do: throw({:exceeded, :task, ts})
          :ok
      end
    end
  catch
    {:exceeded, tier, status} -> {:exceeded, tier, status}
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    # Create the shared ETS table if it doesn't exist yet (global instance creates it;
    # tenant instances reuse it since keys are scoped by tenant prefix)
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, read_concurrency: true])
    end

    tenant_id = Keyword.get(opts, :tenant_id)
    cost_events_path = Keyword.get(opts, :cost_events_path, "cost-events.jsonl")

    # Only the global instance loads from the jsonl file
    if tenant_id == nil do
      load_cost_events(cost_events_path)
    end

    schedule_refresh()

    if tenant_id do
      Logger.info("BudgetTracker started for tenant #{tenant_id}")
    else
      Logger.info("BudgetTracker started (global)")
    end

    {:ok,
     %{
       tenant_id: tenant_id,
       cost_events_path: cost_events_path,
       recent_events: [],
       file_offset: 0
     }}
  end

  @impl true
  def handle_call({:recent_events, limit}, _from, state) do
    {:reply, Enum.take(state.recent_events, limit), state}
  end

  # Handle old 3-arg pattern for backward compatibility
  @impl true
  def handle_cast({:record_cost, agent_id, amount}, state) do
    handle_cast({:record_cost, agent_id, amount, []}, state)
  end

  @impl true
  def handle_cast({:record_cost, agent_id, amount, opts}, state) do
    tenant_id = state.tenant_id
    today = Date.utc_today() |> Date.to_iso8601()

    # Daily total (tenant-scoped if tenant instance)
    add_cost(ets_key(tenant_id, today), amount)

    # Per-agent total
    add_cost(ets_key(tenant_id, {:agent, agent_id}), amount)

    # Per-task total (if provided)
    case Keyword.get(opts, :task_id) do
      nil -> :ok
      task_id -> add_cost(ets_key(tenant_id, {:task, task_id}), amount)
    end

    event = %{
      timestamp: DateTime.utc_now(),
      session: agent_id,
      cost_usd: amount,
      task_id: Keyword.get(opts, :task_id),
      tenant_id: tenant_id,
      tool: "unknown"
    }

    recent = [event | state.recent_events] |> Enum.take(500)
    {:noreply, %{state | recent_events: recent}}
  end

  @impl true
  def handle_info(:refresh, state) do
    state =
      if state.tenant_id == nil do
        new_offset = load_cost_events_incremental(state.cost_events_path, state.file_offset)
        %{state | file_offset: new_offset}
      else
        state
      end

    schedule_refresh()
    {:noreply, state}
  end

  # --- Private ---

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  # Build an ETS key scoped to a tenant (or raw for global instance)
  defp ets_key(nil, key), do: key
  defp ets_key(tenant_id, key), do: {:tenant, tenant_id, key}

  # Reads cost from ETS, converting from micro-dollars back to dollars.
  defp read_cost(key) do
    case :ets.lookup(@table, key) do
      [{^key, micro}] when is_integer(micro) -> micro / 1_000_000
      [{^key, float_val}] when is_float(float_val) -> float_val
      [] -> 0.0
    end
  end

  defp add_cost(key, amount) do
    # Atomic increment — avoids race when concurrent processes record costs.
    # update_counter requires integer increments, so we store costs as
    # integer micro-dollars (millionths of a dollar) for atomicity.
    micro = trunc(amount * 1_000_000)

    try do
      :ets.update_counter(@table, key, {2, micro})
    rescue
      ArgumentError ->
        # Key doesn't exist yet — insert and retry once for the race
        # where two processes both see the key missing simultaneously.
        :ets.insert_new(@table, {key, 0})
        :ets.update_counter(@table, key, {2, micro})
    end
  end

  # Full load on startup (reads entire file, returns final byte offset).
  defp load_cost_events(path) do
    load_cost_events_incremental(path, 0)
  end

  # Incremental load — seeks to `offset`, reads only new bytes, returns new offset.
  # This avoids re-reading the entire file every 10s refresh cycle.
  defp load_cost_events_incremental(path, offset) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= offset ->
        # No new data
        offset

      {:ok, %{size: _size}} ->
        {:ok, fd} = File.open(path, [:read, :binary])

        if offset > 0 do
          {:ok, _} = :file.position(fd, offset)
        end

        new_offset = read_lines_from(fd, offset)
        File.close(fd)
        new_offset

      {:error, :enoent} ->
        0
    end
  rescue
    e ->
      Logger.warning("Failed to load cost events: #{inspect(e)}")
      offset
  end

  defp read_lines_from(fd, offset) do
    case IO.read(fd, :line) do
      :eof ->
        offset

      {:error, _reason} ->
        offset

      line when is_binary(line) ->
        parse_cost_line(line)
        read_lines_from(fd, offset + byte_size(line))
    end
  end

  defp parse_cost_line(line) do
    case Jason.decode(line) do
      # Pre-aggregated format: {"date": "2026-03-09", "cost": 0.50}
      {:ok, %{"date" => date, "cost" => cost}} when is_number(cost) ->
        add_cost(date, cost)

      # Raw cost event format: {"timestamp": "...", "costUsd": 0.10, ...}
      {:ok, %{"timestamp" => ts, "costUsd" => cost}} when is_number(cost) and cost > 0 ->
        date = String.slice(ts, 0, 10)
        add_cost(date, cost)

      _ ->
        :ok
    end
  end
end
