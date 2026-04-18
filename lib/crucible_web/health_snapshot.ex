defmodule CrucibleWeb.HealthSnapshot do
  @moduledoc """
  Shared native health snapshot builder for API and LiveView overview surfaces.
  """

  alias Crucible.{
    BudgetTracker,
    ExecutorLock,
    LLMUsageReader,
    MemoryHealthReader,
    ModelRegistry,
    Orchestrator,
    RouterHealthReader,
    SavingsReader
  }

  alias CrucibleWeb.RouteMetrics

  @health_latency_breach_ms 2_000
  @default_budget_status %{
    daily_spent: 0.0,
    daily_limit: 100.0,
    daily_remaining: 100.0,
    is_over_budget: false,
    event_count: 0
  }

  @spec build_full_health(keyword()) :: map()
  def build_full_health(opts \\ []) do
    budget =
      case Keyword.get(opts, :budget) do
        nil -> budget_status()
        status -> budget_status_from_struct(status)
      end

    runs =
      Keyword.get_lazy(opts, :runs, fn ->
        safe_call(fn -> Orchestrator.list_runs() end, [])
      end)

    db_ok = Keyword.get_lazy(opts, :db_ok, &db_ok?/0)
    circuits = safe_call(fn -> ModelRegistry.circuit_states() end, %{})
    route_metrics = RouteMetrics.snapshot()
    health_route = health_route_metrics(route_metrics["routes"] || [])

    %{
      "status" => overall_status(budget, db_ok, route_metrics, health_route),
      "version" => System.get_env("BUILD_VERSION") || "dev",
      "commit" => System.get_env("BUILD_COMMIT") || "unknown",
      "db" => if(db_ok, do: "connected", else: "unreachable"),
      "budget" => budget,
      "memory" => MemoryHealthReader.health_stats(),
      "savings" => savings_summary(),
      "router" => router_health(circuits),
      "circuits" => circuits,
      "slo" => %{
        "windowMs" => route_metrics["windowMs"] || 0,
        "requestCount" => route_metrics["totalRequests"] || 0,
        "totalErrors" => route_metrics["totalErrors"] || 0,
        "errorRate" => route_metrics["errorRate"] || 0.0,
        "p95Ms" => route_metrics["p95Ms"] || 0.0,
        "healthRoute" => %{
          "p95Ms" => health_route["p95Ms"] || 0.0,
          "requestCount" => health_route["requestCount"] || 0
        },
        "routes" => Enum.take(route_metrics["routes"] || [], 20),
        "alerts" => route_metrics["alerts"] || []
      },
      "runs" => run_summary(runs),
      "executor" => executor_status(runs),
      "dataFeeds" => data_feed_stats(),
      "monitoring" => %{
        "grafanaUrl" => System.get_env("GRAFANA_URL") || "http://localhost:3000",
        "prometheusUrl" => System.get_env("PROMETHEUS_URL") || "http://localhost:9090"
      }
    }
  end

  @spec budget_status() :: map()
  def budget_status do
    safe_call(fn -> BudgetTracker.status() end, @default_budget_status)
    |> budget_status_from_struct()
  end

  @spec budget_status_from_struct(map()) :: map()
  def budget_status_from_struct(status) when is_map(status) do
    %{
      "dailySpent" =>
        status_value(status, [:daily_spent, "daily_spent", :dailySpent, "dailySpent"], 0.0),
      "dailyLimit" =>
        status_value(status, [:daily_limit, "daily_limit", :dailyLimit, "dailyLimit"], 100.0),
      "dailyRemaining" =>
        status_value(
          status,
          [:daily_remaining, "daily_remaining", :dailyRemaining, "dailyRemaining"],
          100.0
        ),
      "isOverBudget" =>
        status_value(
          status,
          [:is_over_budget, "is_over_budget", :isOverBudget, "isOverBudget"],
          false
        ),
      "eventCount" =>
        status_value(status, [:event_count, "event_count", :eventCount, "eventCount"], 0) ||
          recent_event_count()
    }
  end

  def budget_status_from_struct(_), do: budget_status_from_struct(@default_budget_status)

  @spec recent_event_count() :: non_neg_integer()
  def recent_event_count do
    safe_call(fn -> BudgetTracker.recent_events(500) end, [])
    |> length()
  end

  @spec savings_summary() :: map()
  def savings_summary do
    savings =
      safe_call(fn -> SavingsReader.build_stats() end, %{
        "totalSavedRatio" => 0.0,
        "totalSavedTokens" => 0,
        "totalEvents" => 0
      })

    %{
      "totalSavedRatio" => savings["totalSavedRatio"] || 0.0,
      "totalSavedTokens" => savings["totalSavedTokens"] || 0,
      "totalEvents" => savings["totalEvents"] || 0
    }
  end

  @spec router_health() :: map()
  def router_health do
    router_health(%{})
  end

  @spec router_health(map()) :: map()
  def router_health(_circuits), do: safe_call(fn -> RouterHealthReader.health() end, %{})

  @spec executor_status(list()) :: map()
  def executor_status(runs \\ [])

  def executor_status(runs) when is_list(runs) do
    repo_root = repo_root()
    lock_path = Path.join([repo_root, ".claude-flow", "executor.lock"])
    active_runs = run_summary(runs)["active"] || 0

    instances =
      case ExecutorLock.read_lock(lock_path) do
        {:ok, lock} ->
          if ExecutorLock.pid_alive?(lock.pid) and fresh_heartbeat?(lock.heartbeat_at) do
            [
              %{
                "instanceId" => "local-executor",
                "pid" => lock.pid,
                "activeRuns" => active_runs,
                "timestamp" =>
                  DateTime.from_unix!(lock.heartbeat_at, :millisecond) |> DateTime.to_iso8601()
              }
            ]
          else
            []
          end

        :not_found ->
          []
      end

    %{
      "natsConnected" => false,
      "instanceCount" => length(instances),
      "instances" => instances
    }
  rescue
    _ ->
      %{"natsConnected" => false, "instanceCount" => 0, "instances" => []}
  end

  @spec data_feed_stats() :: map()
  def data_feed_stats do
    entries =
      LLMUsageReader.cache_entries() +
        SavingsReader.cache_entries() +
        RouteMetrics.sample_count()

    %{
      "entries" => entries,
      "hits" => 0,
      "misses" => 0,
      "evictions" => 0,
      "hitRate" => 0.0
    }
  end

  @spec run_summary(list()) :: map()
  def run_summary(runs) do
    pending = Enum.count(runs, &(&1.status == :pending))
    running = Enum.count(runs, &(&1.status in [:running, :in_progress]))
    review = Enum.count(runs, &(&1.status == :review))
    failed = Enum.count(runs, &(&1.status == :failed))
    orphaned = Enum.count(runs, &(&1.status == :orphaned))
    done = Enum.count(runs, &(&1.status in [:done, :completed]))
    active = pending + running + review

    oldest_active_minutes =
      runs
      |> Enum.filter(&(&1.status in [:pending, :running, :in_progress, :review]))
      |> Enum.map(&run_timestamp_ms/1)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        values -> values |> Enum.min() |> age_minutes()
      end

    %{
      "total" => length(runs),
      "active" => active,
      "pending" => pending,
      "running" => running,
      "review" => review,
      "failed" => failed,
      "orphaned" => orphaned,
      "done" => done,
      "oldestActiveMinutes" => oldest_active_minutes
    }
  end

  defp overall_status(budget, db_ok, route_metrics, health_route) do
    error_rate_breached = (route_metrics["errorRate"] || 0.0) > 0.05
    latency_breached = (health_route["p95Ms"] || 0.0) > @health_latency_breach_ms

    if db_ok and not (budget["isOverBudget"] || false) and not error_rate_breached and
         not latency_breached do
      "ok"
    else
      "degraded"
    end
  end

  defp health_route_metrics(routes) do
    Enum.find(routes, %{}, fn route ->
      route["method"] == "GET" and route["route"] == "/api/health"
    end)
  end

  defp db_ok? do
    case Crucible.Repo.query("SELECT 1") do
      {:ok, _} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end

  defp status_value(status, keys, default) do
    Enum.find_value(keys, default, fn key ->
      case Map.fetch(status, key) do
        {:ok, value} -> value
        :error -> false
      end
    end)
  end

  defp run_timestamp_ms(%{started_at: %DateTime{} = started_at}),
    do: DateTime.to_unix(started_at, :millisecond)

  defp run_timestamp_ms(%{started_at: started_at}) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp run_timestamp_ms(_), do: nil

  defp age_minutes(ts_ms) do
    max(System.system_time(:millisecond) - ts_ms, 0)
    |> Kernel./(60_000)
    |> round()
  end

  defp fresh_heartbeat?(heartbeat_at) when is_integer(heartbeat_at) do
    System.system_time(:millisecond) - heartbeat_at < 30_000
  end

  defp fresh_heartbeat?(_), do: false

  defp repo_root do
    Application.get_env(:crucible, :orchestrator, [])
    |> Keyword.get(:repo_root, File.cwd!())
  end
end
