defmodule Crucible.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # OpenTelemetry auto-instrumentation (must run before supervision tree)
    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryEcto.setup([:crucible, :repo], db_statement: :disabled)
    OpentelemetryBandit.setup()

    # Validate required config in prod (fail fast on misconfiguration)
    Crucible.ConfigValidator.validate!()

    # Audit .env file permissions and placeholder secrets (non-fatal warnings)
    Crucible.SecretsAudit.check()

    # Add LogBuffer backend to Logger (programmatic to avoid deprecated :backends config)
    :logger.add_handler(:log_buffer, Crucible.LogBuffer.Handler, %{level: :all})

    # Sentry error handler — captures Logger.error and unhandled exceptions
    :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{
      config: %{metadata: [:request_id, :run_id, :phase_id]},
      level: :error
    })

    # Distributed components (libcluster + Horde) — optional in single-node mode
    distributed_children =
      if Application.get_env(:crucible, :distributed, false) do
        [
          Crucible.Cluster.Topology,
          Crucible.Cluster.DistributedRegistry,
          {Horde.DynamicSupervisor,
           name: Crucible.DistributedSupervisor, strategy: :one_for_one, members: :auto},
          # Mnesia-backed distributed state store (must start after cluster topology)
          Crucible.State.DistributedStore
        ]
      else
        []
      end

    orchestrator_opts = Application.get_env(:crucible, :orchestrator, [])
    repo_root = Keyword.get(orchestrator_opts, :repo_root, File.cwd!())

    self_improvement_interval_ms =
      Keyword.get(orchestrator_opts, :self_improvement_interval_ms, 1_800_000)

    cost_events_path = Path.join(repo_root, ".claude-flow/logs/cost-events.jsonl")

    # --- Database layer (isolated: Repo restarts independently without cascading) ---
    repo_children = [
      Crucible.Repo
    ]

    # --- Infrastructure layer (rest_for_one: ordered dependencies) ---
    infra_children = [
      # Rate limit DETS persistence (seeds ETS from prior snapshot on startup)
      Crucible.RateLimitPersistence,

      # Telemetry
      CrucibleWeb.Telemetry,

      # Native route/SLO metrics for the health dashboard
      CrucibleWeb.RouteMetrics,

      # Legacy DNS cluster (retained for non-libcluster environments)
      {DNSCluster,
       query: Application.get_env(:crucible, :dns_cluster_query) || :ignore},

      # PubSub for real-time updates to LiveView dashboard
      # When manifold_pubsub is enabled, uses ManifoldAdapter for parallel fan-out;
      # otherwise falls back to standard PG2 dispatch.
      pubsub_child(manifold_enabled?()),

      # Topic registry for direct Manifold fan-out with subscriber tracking
      # (started regardless — no-ops gracefully when Manifold is disabled)
      Crucible.PubSub.TopicRegistry,

      # Local process registry for run lookup by ID (fast local-only path)
      {Registry, keys: :unique, name: Crucible.RunRegistry},

      # Tenant registry and dynamic supervisor for per-tenant isolation
      Crucible.Tenant.Registry,
      Crucible.Tenant.Supervisor,

      # Per-tenant concurrency limiting via ETS counters
      Crucible.Bulkhead
    ]

    # --- Core services layer (rest_for_one: ordered dependencies) ---
    core_children = [
      # Task supervisor for agent run spawning (used by RunServer)
      {Task.Supervisor, name: Crucible.TaskSupervisor},

      # DynamicSupervisor for per-run GenServers
      Crucible.Orchestrator.RunSupervisor,

      # DynamicSupervisor for SDK Port processes (one per phase execution)
      {DynamicSupervisor, name: Crucible.SdkPortSupervisor, strategy: :one_for_one},

      # Workflow YAML cache (polls for file changes)
      {Crucible.WorkflowStore,
       workflows_dir: Application.get_env(:crucible, :workflows_dir, "workflows")},

      # Budget tracker (ETS-backed cost accumulator)
      {Crucible.BudgetTracker, cost_events_path: cost_events_path},

      # Result writer (serialized run manifest I/O)
      Crucible.ResultWriter,

      # Core orchestrator (poll/dispatch/reconcile loop)
      Crucible.Orchestrator
    ]

    # --- Auxiliary services (one_for_one: independent, can restart individually) ---
    aux_children = [
      # Runtime feature flags (ETS-backed, togglable without restart)
      Crucible.FeatureFlags,

      # Control panel session manager (interactive Claude terminals)
      Crucible.ControlSession,

      # Cost event writer (serialized JSONL append from SdkPort streaming)
      {Crucible.CostEventWriter, file_path: cost_events_path},

      # Trace event writer (JSONL + DB batch from SdkPort streaming)
      {Crucible.TraceEventWriter, traces_dir: Path.join(repo_root, ".claude-flow/logs/traces")},

      # Elixir SDK session transcript writer (serialized JSONL append per session)
      Crucible.ElixirSdk.Transcript,

      # Elixir SDK Task.Supervisor (per-query streaming tasks)
      {Task.Supervisor, name: Crucible.ElixirSdk.TaskSupervisor},

      # Elixir SDK MCP client (stdio / http servers; registers remote tools)
      Crucible.ElixirSdk.Mcp.Client,

      # Cost event reader (tails cost-events.jsonl for session activity)
      {Crucible.CostEventReader, file_path: cost_events_path},

      # Circuit breakers for external HTTP services (model router, TS dashboard)
      Crucible.ExternalCircuitBreaker,

      # Sandbox pool manager (pre-warms Docker containers for API workflow isolation)
      Crucible.Sandbox.Manager,

      # In-memory ring buffer for Elixir server logs
      Crucible.LogBuffer,

      # Audit logger for auth/security events → audit.jsonl
      Crucible.AuditLogger,

      # Alert manager (subscribes to alert feed, dispatches webhooks)
      Crucible.AlertManager,

      # Self-improvement (periodic KPI/hint generation)
      {Crucible.SelfImprovement,
       infra_home: repo_root, interval_ms: self_improvement_interval_ms},

      # Transcript tailer (tails session JSONL files, broadcasts tool events via PubSub)
      Crucible.TranscriptTailer,

      # Remote session tracker (powers Phoenix Remote tab + API start/stop/status)
      {Crucible.RemoteSessionTracker, repo_root: repo_root},

      # Job queue (PatrolScanner and future periodic jobs)
      {Oban, Application.fetch_env!(:crucible, Oban)},

      # Phoenix endpoint (HTTP server + LiveView WebSocket)
      CrucibleWeb.Endpoint
    ]

    children =
      distributed_children ++
        [
          # Database: isolated supervisor — Repo restarts don't cascade to other services
          %{
            id: Crucible.RepoSupervisor,
            type: :supervisor,
            start:
              {Supervisor, :start_link,
               [repo_children, [strategy: :one_for_one, name: Crucible.RepoSupervisor]]}
          },

          # Infrastructure: PubSub, Registry, Tenants — rest_for_one ensures dependents restart
          %{
            id: Crucible.InfraSupervisor,
            type: :supervisor,
            start:
              {Supervisor, :start_link,
               [
                 infra_children,
                 [strategy: :rest_for_one, name: Crucible.InfraSupervisor]
               ]}
          },

          # Core: TaskSupervisor → RunSupervisor → WorkflowStore → BudgetTracker → Orchestrator
          %{
            id: Crucible.CoreSupervisor,
            type: :supervisor,
            start:
              {Supervisor, :start_link,
               [core_children, [strategy: :rest_for_one, name: Crucible.CoreSupervisor]]}
          },

          # Aux: independent services that can restart individually
          %{
            id: Crucible.AuxSupervisor,
            type: :supervisor,
            start:
              {Supervisor, :start_link,
               [aux_children, [strategy: :one_for_one, name: Crucible.AuxSupervisor]]}
          }
        ]

    # Attach Oban telemetry BEFORE starting the tree so handlers are
    # in place when the first cron job fires.
    Crucible.ObanTelemetry.attach()

    opts = [strategy: :one_for_one, name: Crucible.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp manifold_enabled? do
    Application.get_env(:crucible, :manifold_pubsub, [])
    |> Keyword.get(:enabled, false)
  end

  defp pubsub_child(true = _manifold) do
    {Phoenix.PubSub,
     name: Crucible.PubSub,
     adapter: Crucible.PubSub.ManifoldAdapter}
  end

  defp pubsub_child(false = _manifold) do
    {Phoenix.PubSub, name: Crucible.PubSub}
  end

  @impl true
  def prep_stop(state) do
    # Drain Oban queues gracefully before shutdown
    Oban.drain_queue(queue: :default, with_safety: true)
    Oban.drain_queue(queue: :patrol, with_safety: true)
    state
  rescue
    e ->
      Logger.warning("prep_stop: Oban drain failed: #{Exception.message(e)}")
      state
  end

  @impl true
  def config_change(changed, _new, removed) do
    CrucibleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
