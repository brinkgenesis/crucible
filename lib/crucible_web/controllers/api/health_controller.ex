defmodule CrucibleWeb.Api.HealthController do
  @moduledoc """
  Kubernetes-compatible health probes with real dependency checks.

  | Probe     | Purpose                  | Checks                                            |
  |-----------|--------------------------|---------------------------------------------------|
  | `live`    | BEAM responsive           | Trivial (timestamp)                               |
  | `ready`   | Accept traffic            | Repo pool, Orchestrator alive, BudgetTracker ETS  |
  | `startup` | App fully initialized     | Repo query, WorkflowStore has workflows, Oban up  |
  | `index`   | Full dashboard status     | All above + budget/runs summary                   |
  """
  use CrucibleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Crucible.{Orchestrator, WorkflowStore}
  alias CrucibleWeb.{HealthSnapshot, RouteMetrics}
  alias CrucibleWeb.Schemas.Common.{HealthResponse}

  @check_timeout_ms 2_000
  @db_check_timeout_ms 5_000
  @pool_utilization_threshold 0.8

  # --- Liveness: BEAM responsive ---

  operation(:live,
    summary: "Liveness probe",
    description: "Returns 200 if the BEAM is responsive. Use for Kubernetes liveness probes.",
    tags: ["Health"],
    responses: [ok: {"Liveness response", "application/json", HealthResponse}]
  )

  def live(conn, _params) do
    json(conn, %{status: "ok", timestamp: DateTime.utc_now() |> DateTime.to_iso8601()})
  end

  # --- Readiness: can serve traffic ---

  operation(:ready,
    summary: "Readiness probe",
    description:
      "Returns 200 if the app can serve traffic (DB, Orchestrator, BudgetTracker). Use for Kubernetes readiness probes.",
    tags: ["Health"],
    responses: [
      ok: {"Ready", "application/json", HealthResponse},
      service_unavailable: {"Not ready", "application/json", HealthResponse}
    ]
  )

  def ready(conn, _params) do
    checks = run_checks([:repo, :orchestrator, :budget_ets]) ++ slo_check()
    respond_with_checks(conn, checks)
  end

  # --- Startup: fully initialized ---

  operation(:startup,
    summary: "Startup probe",
    description:
      "Returns 200 when the app is fully initialized (DB, workflows loaded, Oban). Use for Kubernetes startup probes.",
    tags: ["Health"],
    responses: [
      ok: {"Started", "application/json", HealthResponse},
      service_unavailable: {"Not started", "application/json", HealthResponse}
    ]
  )

  def startup(conn, _params) do
    checks = run_checks([:repo, :workflows, :oban])
    respond_with_checks(conn, checks)
  end

  operation(:executor,
    summary: "Executor health",
    description: "Returns local executor lock status and instance metadata.",
    tags: ["Health"],
    responses: [ok: {"Executor status", "application/json", HealthResponse}]
  )

  def executor(conn, _params) do
    json(conn, HealthSnapshot.executor_status())
  end

  # --- Index: full system health ---

  operation(:index,
    summary: "Full system health",
    description:
      "Comprehensive health check including dependency status, budget, and run counts.",
    tags: ["Health"],
    security: [%{"cookieAuth" => []}],
    responses: [ok: {"System health", "application/json", HealthResponse}]
  )

  def index(conn, _params) do
    checks = run_checks([:repo, :orchestrator, :budget_ets, :workflows, :oban]) ++ slo_check()

    runs = safe_call(fn -> Orchestrator.list_runs() end, [])
    repo_ok = Enum.any?(checks, &(&1.name == "repo" and &1.status != "error"))
    snapshot = HealthSnapshot.build_full_health(runs: runs, db_ok: repo_ok)

    json(conn, Map.put(snapshot, "checks", checks))
  end

  # --- Check execution ---

  defp run_checks(check_names) do
    check_names
    |> Enum.map(fn name ->
      task = Task.async(fn -> run_single_check(name) end)
      timeout = check_timeout(name)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, result} -> result
        nil -> %{name: to_string(name), status: "error", message: "timeout"}
      end
    end)
  end

  defp check_timeout(:repo), do: @db_check_timeout_ms
  defp check_timeout(_), do: @check_timeout_ms

  defp slo_check do
    route_metrics = RouteMetrics.snapshot()

    if (route_metrics["errorRate"] || 0.0) > 0.05 do
      [
        %{
          name: "slo",
          status: "degraded",
          message: "API error rate above 5%"
        }
      ]
    else
      []
    end
  end

  defp run_single_check(:repo) do
    start = System.monotonic_time(:millisecond)

    case Crucible.Repo.query("SELECT 1") do
      {:ok, _} ->
        elapsed = System.monotonic_time(:millisecond) - start
        pool_stats = fetch_pool_stats()
        base = %{name: "repo", status: "ok", db_response_ms: elapsed}
        merge_pool_stats(base, pool_stats)

      {:error, reason} ->
        elapsed = System.monotonic_time(:millisecond) - start
        %{name: "repo", status: "error", message: inspect(reason), db_response_ms: elapsed}
    end
  end

  defp run_single_check(:orchestrator) do
    if GenServer.whereis(Orchestrator) do
      %{name: "orchestrator", status: "ok"}
    else
      %{name: "orchestrator", status: "error", message: "not running"}
    end
  end

  defp run_single_check(:budget_ets) do
    if :ets.whereis(:budget_costs) != :undefined do
      %{name: "budget_ets", status: "ok"}
    else
      %{name: "budget_ets", status: "error", message: "ETS table missing"}
    end
  end

  defp run_single_check(:workflows) do
    case safe_call(fn -> WorkflowStore.list() end, :error) do
      workflows when is_list(workflows) and length(workflows) > 0 ->
        %{name: "workflows", status: "ok", count: length(workflows)}

      [] ->
        %{name: "workflows", status: "error", message: "no workflows loaded"}

      :error ->
        %{name: "workflows", status: "error", message: "WorkflowStore unavailable"}
    end
  end

  defp run_single_check(:oban) do
    if GenServer.whereis(Oban) do
      %{name: "oban", status: "ok"}
    else
      %{name: "oban", status: "error", message: "not running"}
    end
  end

  # --- Pool stats helpers ---

  defp fetch_pool_stats do
    config = Crucible.Repo.config()
    pool_size = Keyword.get(config, :pool_size, 10)

    case Crucible.Repo.query(
           "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND state = 'active'"
         ) do
      {:ok, %{rows: [[active_count]]}} ->
        checked_out = active_count
        available = max(pool_size - checked_out, 0)
        %{pool_size: pool_size, checked_out: checked_out, available: available}

      _ ->
        %{pool_size: pool_size, checked_out: 0, available: pool_size}
    end
  rescue
    _ -> nil
  end

  defp merge_pool_stats(base, nil), do: base

  defp merge_pool_stats(base, %{pool_size: size, checked_out: out, available: avail}) do
    utilization = if size > 0, do: out / size, else: 0.0
    status = if utilization > @pool_utilization_threshold, do: "degraded", else: base.status

    Map.merge(base, %{
      status: status,
      pool: %{
        pool_size: size,
        checked_out: out,
        available: avail,
        utilization: Float.round(utilization, 2)
      }
    })
  end

  defp respond_with_checks(conn, checks) do
    has_errors = Enum.any?(checks, &(&1.status == "error"))
    has_degraded = Enum.any?(checks, &(&1.status == "degraded"))
    status_code = if has_errors, do: 503, else: 200

    overall =
      cond do
        has_errors -> "degraded"
        has_degraded -> "degraded"
        true -> "ok"
      end

    conn
    |> put_status(status_code)
    |> json(%{status: overall, checks: checks})
  end
end
