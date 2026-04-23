defmodule CrucibleWeb.Plugs.TenantId do
  @moduledoc """
  Extracts tenant_id from the `x-tenant-id` request header and assigns it.

  Returns 400 if the header is missing or empty.
  """
  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_req_header(conn, "x-tenant-id") do
      [tenant_id] when tenant_id != "" ->
        assign(conn, :tenant_id, tenant_id)

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "missing x-tenant-id header"}))
        |> halt()
    end
  end
end

defmodule CrucibleWeb.TenantController do
  @moduledoc """
  Handles tenant-scoped API endpoints.

  Routes are mounted under /api/tenants/:tenant_id and require the
  x-tenant-id header to match the path parameter.
  """
  use CrucibleWeb, :controller

  alias Crucible.Tenant.Supervisor, as: TenantSupervisor
  alias Crucible.Tenant.Registry, as: TenantRegistry
  alias Crucible.BudgetTracker

  def submit_run(conn, %{"tenant_id" => tenant_id} = params) do
    with :ok <- verify_tenant_id(conn, tenant_id),
         {:ok, _pid} <- TenantSupervisor.ensure_tenant(tenant_id) do
      run_manifest =
        params
        |> Map.delete("tenant_id")
        |> Map.put("tenant_id", tenant_id)

      # Route to the tenant-scoped orchestrator via registry
      case TenantRegistry.lookup(tenant_id) do
        {:ok, _pid} ->
          json(conn, %{status: "accepted", tenant_id: tenant_id, run: run_manifest})

        :error ->
          conn |> put_status(500) |> json(%{error: "tenant_supervisor_not_found"})
      end
    else
      {:error, :tenant_mismatch} ->
        conn |> put_status(403) |> json(%{error: "tenant_id mismatch"})

      {:error, reason} ->
        require Logger
        Logger.error("TenantController: submit_run failed: #{inspect(reason)}")
        conn |> put_status(500) |> json(%{error: "internal_error"})
    end
  end

  def budget(conn, %{"tenant_id" => tenant_id}) do
    with :ok <- verify_tenant_id(conn, tenant_id) do
      status =
        try do
          BudgetTracker.status()
        rescue
          _ ->
            %{daily_spent: 0.0, daily_limit: 100.0, daily_remaining: 100.0, is_over_budget: false}
        catch
          :exit, _ ->
            %{daily_spent: 0.0, daily_limit: 100.0, daily_remaining: 100.0, is_over_budget: false}
        end

      json(conn, %{
        tenant_id: tenant_id,
        daily_spent: status.daily_spent,
        daily_limit: status.daily_limit,
        daily_remaining: status.daily_remaining,
        is_over_budget: status.is_over_budget
      })
    else
      {:error, :tenant_mismatch} ->
        conn |> put_status(403) |> json(%{error: "tenant_id mismatch"})
    end
  end

  def stop(conn, %{"tenant_id" => tenant_id}) do
    with :ok <- verify_tenant_id(conn, tenant_id) do
      case TenantSupervisor.stop_tenant(tenant_id) do
        :ok ->
          json(conn, %{status: "stopped", tenant_id: tenant_id})

        {:error, :not_found} ->
          conn |> put_status(404) |> json(%{error: "tenant not found"})
      end
    else
      {:error, :tenant_mismatch} ->
        conn |> put_status(403) |> json(%{error: "tenant_id mismatch"})
    end
  end

  # Verify the x-tenant-id header matches the URL tenant_id
  defp verify_tenant_id(conn, tenant_id) do
    if conn.assigns[:tenant_id] == tenant_id do
      :ok
    else
      {:error, :tenant_mismatch}
    end
  end
end

defmodule CrucibleWeb.Router do
  use CrucibleWeb, :router

  @script_src (if Mix.env() == :dev do
                 "script-src 'self' 'unsafe-eval'; "
               else
                 "script-src 'self'; "
               end)

  # Shared secure-browser headers applied to every browser request.
  # LiveView needs `ws:`/`wss:` connect for its socket. Dev keeps
  # `unsafe-eval` for source maps; production does not.
  @secure_browser_headers %{
    "x-frame-options" => "DENY",
    "x-content-type-options" => "nosniff",
    "x-xss-protection" => "1; mode=block",
    "referrer-policy" => "strict-origin-when-cross-origin",
    "permissions-policy" => "camera=(), microphone=(), geolocation=()",
    "content-security-policy" =>
      "default-src 'self'; " <>
        @script_src <>
        "style-src 'self' https://fonts.googleapis.com; " <>
        "img-src 'self' data: blob:; " <>
        "font-src 'self' data: https://fonts.gstatic.com; " <>
        "connect-src 'self' ws: wss:; " <>
        "frame-ancestors 'none'; " <>
        "base-uri 'self'; " <>
        "form-action 'self'; " <>
        "object-src 'none'"
  }

  pipeline :browser do
    plug CrucibleWeb.Plugs.RequestId
    plug CrucibleWeb.Plugs.LogContext
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_cookies
    plug :fetch_live_flash
    plug :put_root_layout, html: {CrucibleWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, @secure_browser_headers

    plug CrucibleWeb.Plugs.CopySidToSession
    plug CrucibleWeb.Plugs.SessionAuth
  end

  pipeline :browser_public do
    plug CrucibleWeb.Plugs.RequestId
    plug CrucibleWeb.Plugs.LogContext
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_cookies
    plug :fetch_live_flash
    plug :put_root_layout, html: {CrucibleWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, @secure_browser_headers
  end

  pipeline :api do
    plug CrucibleWeb.Plugs.RequestId
    plug CrucibleWeb.Plugs.LogContext
    plug CrucibleWeb.Plugs.RouteMetrics
    plug :accepts, ["json"]
    plug CrucibleWeb.Plugs.ValidateContentType
    plug CrucibleWeb.Plugs.CORS
    plug CrucibleWeb.Plugs.RateLimit
    plug OpenApiSpex.Plug.PutApiSpec, module: CrucibleWeb.ApiSpec
  end

  pipeline :api_auth do
    plug CrucibleWeb.Plugs.Auth
    plug CrucibleWeb.Plugs.RBAC
  end

  pipeline :browser_rate_limited do
    plug CrucibleWeb.Plugs.RateLimit
  end

  pipeline :benchmark_public do
    plug :put_benchmark_public
  end

  pipeline :tenant do
    plug CrucibleWeb.Plugs.TenantId
  end

  # OpenAPI spec + Swagger UI — no auth required
  scope "/api" do
    pipe_through :api
    get "/openapi", OpenApiSpex.Plug.RenderSpec, []
  end

  scope "/api" do
    pipe_through :browser
    get "/docs", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi"
  end

  # Health probes — no auth required
  scope "/api/health", CrucibleWeb.Api do
    pipe_through :api

    get "/live", HealthController, :live
    get "/ready", HealthController, :ready
    get "/startup", HealthController, :startup
    get "/executor", HealthController, :executor
  end

  # Short alias for liveness so `curl /healthz` works out of the box.
  scope "/", CrucibleWeb.Api do
    pipe_through :api

    get "/healthz", HealthController, :live
  end

  # Internal webhooks — no auth (called by Alertmanager and other infra services)
  scope "/api/v1/webhooks", CrucibleWeb.Api do
    pipe_through :api

    post "/alert", AlertWebhookController, :receive
    post "/github", GithubWebhookController, :receive
    post "/inbox/receive", InboxIngestController, :webhook
  end

  # Prometheus metrics — no auth (scraped by monitoring infra)
  scope "/", CrucibleWeb.Api do
    get "/metrics", MetricsController, :index
  end

  # Authenticated API routes — versioned under /api/v1
  scope "/api/v1", CrucibleWeb.Api do
    pipe_through [:api, :api_auth]

    get "/health", HealthController, :index

    # Budget
    get "/budget/status", BudgetController, :status
    get "/budget/history", BudgetController, :history
    get "/budget/breakdown", BudgetController, :breakdown
    get "/budget/sessions", BudgetController, :sessions
    get "/budget/alerts", BudgetController, :alerts

    # Kanban
    get "/kanban/cards", KanbanController, :index
    post "/kanban/cards", KanbanController, :create
    get "/kanban/cards/:id", KanbanController, :show
    put "/kanban/cards/:id", KanbanController, :update
    delete "/kanban/cards/:id", KanbanController, :delete
    post "/kanban/cards/:id/move", KanbanController, :move
    post "/kanban/cards/:id/archive", KanbanController, :archive
    post "/kanban/cards/:id/restore", KanbanController, :restore
    get "/kanban/cards/:id/history", KanbanController, :history
    post "/kanban/cards/:id/plan", KanbanController, :plan

    # Runs — literal segments before :id
    get "/runs", RunsController, :index
    get "/runs/sessions", RunsController, :sessions
    get "/runs/:id", RunsController, :show
    get "/runs/:id/loops", RunsController, :loops
    get "/runs/:id/api-phases", RunsController, :api_phases

    # Traces — literal segments before :id
    get "/traces", TracesController, :index
    get "/traces/dashboard", TracesController, :dashboard
    get "/traces/export/:run_id", TracesController, :export
    get "/traces/:run_id/detail", TracesController, :detail
    get "/traces/:run_id/summary", TracesController, :summary
    get "/traces/:id", TracesController, :show

    # Teams
    get "/teams", TeamsController, :index
    get "/teams/:name", TeamsController, :show
    get "/teams/:name/members", TeamsController, :members
    get "/teams/:name/tasks", TeamsController, :tasks

    # Workflows
    get "/workflows", WorkflowsController, :index
    get "/workflows/:name", WorkflowsController, :show

    # Memory

    # Config
    get "/config", ConfigController, :index
    get "/config/claude-flow", ConfigController, :claude_flow
    put "/config/claude-flow", ConfigController, :update_claude_flow
    get "/config/env", ConfigController, :env
    get "/config/budget", ConfigController, :budget_config
    put "/config/budget", ConfigController, :update_budget

    # Logs
    get "/logs", LogsController, :index
    get "/logs/stream", LogsController, :stream

    # Codebase
    get "/codebase", CodebaseController, :index
    get "/codebase/symbols", CodebaseController, :symbols
    get "/codebase/references", CodebaseController, :references
    get "/codebase/callgraph", CodebaseController, :callgraph
    get "/codebase/impact", CodebaseController, :impact
    get "/codebase/health", CodebaseController, :codebase_health
    get "/codebase/graph", CodebaseController, :graph

    # Webhooks
    post "/webhooks/trigger", WebhookController, :trigger

    # Inbox
    post "/inbox/link", InboxIngestController, :link

    # Agent Jobs (async agent API — P3)

    # Clients

    # Audit
    get "/audit", AuditController, :index

    # Agents
    get "/agents", AgentsController, :index
    get "/agents/stats", AgentsController, :stats
    get "/agents/:name", AgentsController, :show

    # Router
    get "/router/models", RouterController, :models
    get "/router/health", RouterController, :health
    get "/router/circuits", RouterController, :circuits
    post "/router/circuits/:provider/reset", RouterController, :reset_circuit

    # Skills

    # Tokens
    get "/tokens/llm", TokensController, :llm
    get "/tokens/savings", TokensController, :savings
    get "/tokens/daily", TokensController, :daily
    get "/tokens/by-model", TokensController, :by_model

    # Remote
    post "/remote/start", RemoteController, :start
    get "/remote/status", RemoteController, :status
    get "/remote/output", RemoteController, :output
    post "/remote/stop", RemoteController, :stop

    # Token Flow (pipeline, flywheels, KYA, attention)
  end

  # NOTE: Legacy /api scope removed (2026-03-25). All API consumers should use /api/v1.

  # Tenant-scoped API routes — require x-tenant-id header
  scope "/api/tenants/:tenant_id", CrucibleWeb do
    pipe_through [:api, :api_auth, :tenant]

    post "/runs", TenantController, :submit_run
    get "/budget", TenantController, :budget
    delete "/", TenantController, :stop
  end

  # Login/logout — no dashboard auth required
  scope "/", CrucibleWeb do
    pipe_through [:browser, :browser_rate_limited]

    get "/login", SessionController, :new
    delete "/logout", SessionController, :delete
  end

  # OAuth routes (Ueberauth)
  scope "/auth", CrucibleWeb do
    pipe_through [:browser, :browser_rate_limited]

    get "/:provider", SessionController, :request
    get "/:provider/callback", SessionController, :callback
  end

  # Auth API (current user)
  scope "/auth", CrucibleWeb do
    pipe_through [:browser, :browser_rate_limited]

    get "/me", SessionController, :me
  end

  # Dashboard LiveView routes — auth via on_mount hook
  scope "/", CrucibleWeb do
    pipe_through :browser

    live_session :authenticated, on_mount: CrucibleWeb.Live.AuthHook do
      live "/", DashboardLive, :index
      live "/runs", RunsLive, :index
      live "/runs/:id", RunsLive, :show
      live "/traces", TracesLive, :index
      live "/traces/compare/:left_run_id/:right_run_id", TracesLive, :compare
      live "/traces/:run_id", TracesLive, :show
      live "/visual", VisualLive, :index
      live "/visual/:run_id", VisualLive, :show
      live "/kanban", KanbanLive, :index
      live "/budget", BudgetLive, :index
      live "/cost", CostLive, :index
      live "/agents", AgentsLive, :index
      live "/teams", TeamsLive, :index
      live "/teams/:name", TeamsLive, :show
      live "/codebase", CodebaseLive, :index
      live "/logs", LogsLive, :index
      live "/router", RouterLive, :index
      live "/config", ConfigLive, :index
      live "/remote", RemoteLive, :index
      live "/settings", SettingsLive, :index
      live "/workspaces", WorkspacesLive, :index
      live "/control", ControlLive, :index
      live "/policies", PoliciesLive, :index
      live "/audit", AuditLive, :index
    end
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:crucible, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CrucibleWeb.Telemetry
    end
  end

  defp put_benchmark_public(conn, _opts) do
    Plug.Conn.put_private(conn, :benchmark_public, true)
  end
end
