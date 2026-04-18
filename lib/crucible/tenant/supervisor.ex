defmodule Crucible.Tenant.Supervisor do
  @moduledoc """
  DynamicSupervisor that starts a full supervision subtree per tenant.

  Each tenant gets isolated Orchestrator, BudgetTracker, and TaskSupervisor
  processes. One tenant's crashes cannot affect another.
  """

  use DynamicSupervisor

  alias Crucible.Tenant.Registry, as: TenantRegistry

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a full supervision subtree for a tenant.

  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec start_tenant(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_tenant(tenant_id) do
    child_spec = {Crucible.Tenant.Subtree, tenant_id: tenant_id}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Stop the supervision subtree for a tenant.
  """
  @spec stop_tenant(String.t()) :: :ok | {:error, :not_found}
  def stop_tenant(tenant_id) do
    case TenantRegistry.lookup(tenant_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Idempotent start-or-lookup. Returns the existing supervisor PID if the
  tenant is already running, or starts a new subtree.
  """
  @spec ensure_tenant(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_tenant(tenant_id) do
    case TenantRegistry.lookup(tenant_id) do
      {:ok, pid} -> {:ok, pid}
      :error -> start_tenant(tenant_id)
    end
  end
end

defmodule Crucible.Tenant.Subtree do
  @moduledoc """
  Per-tenant Supervisor that owns the tenant's isolated processes.

  Currently starts a TaskSupervisor per tenant. Orchestrator and BudgetTracker
  will be added once those modules support named instances (tenant-aware dispatch).

  Registers itself in the TenantRegistry on init so lookups work.
  """

  use Supervisor

  alias Crucible.Tenant.Registry, as: TenantRegistry

  def start_link(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    Supervisor.start_link(__MODULE__, tenant_id)
  end

  @impl true
  def init(tenant_id) do
    # Register this supervisor PID in the tenant registry
    {:ok, _} = TenantRegistry.register(tenant_id)

    children = [
      {Task.Supervisor, name: via(tenant_id, :task_supervisor)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Build a via-tuple for a tenant-scoped service in the registry."
  def via(tenant_id, service) do
    {:via, Registry, {TenantRegistry.registry_name(), {tenant_id, service}}}
  end
end
