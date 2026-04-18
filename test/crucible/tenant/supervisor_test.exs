defmodule Crucible.Tenant.SupervisorTest do
  use ExUnit.Case, async: false

  alias Crucible.Tenant.Supervisor, as: TenantSupervisor
  alias Crucible.Tenant.Registry, as: TenantRegistry

  setup do
    # Ensure the DynamicSupervisor and Registry are running
    # They should be started by the application supervisor
    on_exit(fn ->
      # Clean up any tenants started during the test
      for tenant_id <- ["test-tenant-a", "test-tenant-b", "test-tenant-c", "crash-tenant"] do
        TenantSupervisor.stop_tenant(tenant_id)
      end
    end)

    :ok
  end

  describe "tenant isolation" do
    test "starting multiple tenants creates isolated supervisor trees" do
      assert {:ok, pid_a} = TenantSupervisor.start_tenant("test-tenant-a")
      assert {:ok, pid_b} = TenantSupervisor.start_tenant("test-tenant-b")

      # Each tenant gets its own supervisor PID
      assert is_pid(pid_a)
      assert is_pid(pid_b)
      assert pid_a != pid_b

      # Both are alive
      assert Process.alive?(pid_a)
      assert Process.alive?(pid_b)
    end

    test "tenant lookup via registry works correctly" do
      {:ok, pid_a} = TenantSupervisor.start_tenant("test-tenant-a")

      assert {:ok, ^pid_a} = TenantRegistry.lookup("test-tenant-a")
      assert :error = TenantRegistry.lookup("nonexistent-tenant")
    end

    test "one tenant crashing doesn't affect another tenant's processes" do
      {:ok, _pid_a} = TenantSupervisor.start_tenant("test-tenant-a")
      {:ok, pid_b} = TenantSupervisor.start_tenant("test-tenant-b")

      # Monitor tenant B so we can verify it stays alive
      ref_b = Process.monitor(pid_b)

      # Terminate tenant A through the DynamicSupervisor (simulates crash cleanup)
      :ok = TenantSupervisor.stop_tenant("test-tenant-a")

      # Give the system a moment to process
      Process.sleep(50)

      # Tenant B should still be alive
      assert Process.alive?(pid_b)

      # Verify no DOWN message for tenant B
      refute_received {:DOWN, ^ref_b, :process, ^pid_b, _}

      # Tenant A should be gone from registry
      assert :error = TenantRegistry.lookup("test-tenant-a")

      # Tenant B registry lookup still works
      assert {:ok, ^pid_b} = TenantRegistry.lookup("test-tenant-b")

      Process.demonitor(ref_b, [:flush])
    end

    test "stopping a tenant cleans up its processes" do
      {:ok, pid} = TenantSupervisor.start_tenant("test-tenant-a")
      assert Process.alive?(pid)

      # Stop the tenant
      assert :ok = TenantSupervisor.stop_tenant("test-tenant-a")

      # Give it time to clean up
      Process.sleep(50)

      # Supervisor should be terminated
      refute Process.alive?(pid)

      # Registry lookup should fail
      assert :error = TenantRegistry.lookup("test-tenant-a")
    end

    test "stopping a nonexistent tenant returns error" do
      assert {:error, :not_found} = TenantSupervisor.stop_tenant("no-such-tenant")
    end

    test "ensure_tenant is idempotent" do
      {:ok, pid1} = TenantSupervisor.ensure_tenant("test-tenant-a")
      {:ok, pid2} = TenantSupervisor.ensure_tenant("test-tenant-a")

      # Same PID returned for the same tenant
      assert pid1 == pid2
    end

    test "budget exhaustion in one tenant doesn't impact another" do
      {:ok, _pid_a} = TenantSupervisor.start_tenant("test-tenant-a")
      {:ok, pid_b} = TenantSupervisor.start_tenant("test-tenant-b")

      # Verify both tenants are registered
      assert {:ok, _} = TenantRegistry.lookup("test-tenant-a")
      assert {:ok, _} = TenantRegistry.lookup("test-tenant-b")

      # Simulate budget exhaustion by stopping tenant A
      assert :ok = TenantSupervisor.stop_tenant("test-tenant-a")
      Process.sleep(50)

      # Tenant B should be completely unaffected
      assert Process.alive?(pid_b)
      assert {:ok, ^pid_b} = TenantRegistry.lookup("test-tenant-b")

      # Tenant A should be gone
      assert :error = TenantRegistry.lookup("test-tenant-a")
    end

    test "starting the same tenant twice returns error" do
      {:ok, _pid} = TenantSupervisor.start_tenant("test-tenant-a")

      # Second start should fail because registry key is taken
      result = TenantSupervisor.start_tenant("test-tenant-a")
      assert {:error, _reason} = result
    end
  end
end
