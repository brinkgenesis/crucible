defmodule CrucibleWeb.Telemetry do
  @moduledoc "Telemetry supervisor — collects Phoenix, Ecto, and orchestrator metrics for Prometheus export."
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
      # Prometheus exporter — scrape via /metrics endpoint
      {TelemetryMetricsPrometheus.Core, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics (distributions → Prometheus histograms)
      distribution("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [10, 50, 100, 250, 500, 1000, 2500]]
      ),
      distribution("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond},
        reporter_options: [buckets: [10, 50, 100, 250, 500, 1000, 2500]]
      ),
      sum("phoenix.socket_drain.count"),

      # Database Metrics
      distribution("crucible.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements",
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500]]
      ),
      distribution("crucible.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection",
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100]]
      ),

      # VM Metrics
      last_value("vm.memory.total", unit: {:byte, :kilobyte}),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),

      # Orchestrator Metrics — Run lifecycle
      counter("orchestrator.run.start.system_time",
        tags: [:workflow_type],
        description: "Count of workflow runs started"
      ),
      distribution("orchestrator.run.stop.duration",
        tags: [:workflow_type, :status],
        unit: {:native, :millisecond},
        description: "Duration of completed workflow runs",
        reporter_options: [buckets: [1000, 5000, 15_000, 30_000, 60_000, 120_000]]
      ),

      # Orchestrator Metrics — Phase lifecycle
      counter("orchestrator.phase.start.system_time",
        tags: [:phase_type],
        description: "Count of phases started"
      ),
      distribution("orchestrator.phase.execute_stop.duration",
        tags: [:phase_type, :status],
        unit: {:native, :millisecond},
        description: "Duration of phase execution",
        reporter_options: [buckets: [1000, 5000, 15_000, 30_000, 60_000]]
      ),

      # Orchestrator Metrics — Budget
      counter("orchestrator.budget.check.system_time",
        tags: [:tier],
        description: "Budget check events by tier"
      ),

      # Security Metrics
      counter("crucible.auth.failure.count",
        description: "Authentication failures"
      ),
      counter("crucible.rate_limit.hit.count",
        description: "Rate limit 429 responses"
      ),
      counter("crucible.session.login.count",
        description: "Dashboard login events"
      ),

      # Alerting Metrics
      counter("crucible.alert.dispatched.count",
        tags: [:severity, :rule],
        description: "Alerts dispatched by severity and rule"
      ),

      # Circuit Breaker Metrics
      last_value("crucible.circuit_breaker.state",
        tags: [:workflow, :state],
        description: "Circuit breaker state (open/half_open/closed) per workflow"
      ),

      # Retry Metrics
      counter("crucible.run.retry.count",
        tags: [:workflow, :reason],
        description: "Workflow run retry events by workflow and failure reason"
      ),

      # Cost Metrics
      sum("crucible.run.cost.total",
        tags: [:workflow, :tenant],
        description: "Total cost (USD) accumulated per workflow and tenant"
      ),

      # Run Duration Distribution
      distribution("crucible.run.duration.milliseconds",
        tags: [:workflow, :status],
        unit: {:native, :millisecond},
        description: "P50/P95/P99 run durations by workflow and completion status",
        reporter_options: [buckets: [1000, 5000, 15_000, 30_000, 60_000, 120_000, 300_000]]
      ),

      # Oban Job Metrics
      distribution("oban.job.stop.duration",
        tags: [:worker, :queue],
        unit: {:native, :millisecond},
        description: "Oban job execution duration",
        reporter_options: [buckets: [100, 500, 1000, 5000, 15_000, 60_000, 120_000]]
      ),
      counter("oban.job.exception.duration",
        tags: [:worker, :queue],
        description: "Oban job exceptions"
      )
    ]
  end

  defp periodic_measurements do
    [
      {__MODULE__, :emit_orchestrator_gauges, []}
    ]
  end

  @doc false
  def emit_orchestrator_gauges do
    # Emit current running count from Registry
    running_count = Registry.count(Crucible.RunRegistry)

    :telemetry.execute(
      [:orchestrator, :runs, :active],
      %{count: running_count},
      %{}
    )
  rescue
    _ -> :ok
  end
end
