defmodule Crucible.Integration.WorkflowIntegrationTest do
  @moduledoc """
  Integration tests for end-to-end workflow execution.
  These tests start the full application and exercise real workflows.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  @moduletag :integration

  setup do
    # Integration tests need a running repo
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Crucible.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Crucible.Repo, {:shared, self()})
    :ok
  end

  describe "workflow submission" do
    test "rejects duplicate run with same idempotency key" do
      tenant_id = "test-tenant-#{System.unique_integer()}"
      idempotency_key = "idem-#{System.unique_integer()}"

      assert {:ok, :new} =
               Crucible.Idempotency.check_and_reserve(idempotency_key, tenant_id)

      assert {:ok, :duplicate, _} =
               Crucible.Idempotency.check_and_reserve(idempotency_key, tenant_id)
    end

    test "allows re-submission after idempotency key expires" do
      # This test verifies that expired keys don't block new submissions
      tenant_id = "test-tenant-#{System.unique_integer()}"
      key = "expired-#{System.unique_integer()}"

      # First submission
      assert {:ok, :new} = Crucible.Idempotency.check_and_reserve(key, tenant_id)

      # Manually expire the key by deleting it from DB
      alias Crucible.Repo
      alias Crucible.Schema.IdempotencyKey
      Repo.delete_all(from k in IdempotencyKey, where: k.key == ^key)

      # Should be allowed again
      assert {:ok, :new} = Crucible.Idempotency.check_and_reserve(key, tenant_id)
    end
  end

  describe "feature flags" do
    test "flags default to configured values" do
      assert is_boolean(Crucible.FeatureFlags.enabled?(:bulkhead_enabled))
    end

    test "flags can be toggled at runtime" do
      Crucible.FeatureFlags.disable(:new_dispatch_algo)
      assert Crucible.FeatureFlags.enabled?(:new_dispatch_algo) == false

      Crucible.FeatureFlags.enable(:new_dispatch_algo)
      assert Crucible.FeatureFlags.enabled?(:new_dispatch_algo) == true

      # Reset
      Crucible.FeatureFlags.disable(:new_dispatch_algo)
    end
  end

  describe "bulkhead isolation" do
    test "allows up to limit concurrent acquisitions" do
      tenant = "tenant-bulkhead-#{System.unique_integer()}"

      # Acquire up to default limit (5)
      results = for _ <- 1..5, do: Crucible.Bulkhead.acquire(tenant)
      assert Enum.all?(results, &(&1 == :ok))

      # 6th should fail
      assert {:error, :bulkhead_full} = Crucible.Bulkhead.acquire(tenant)

      # Release one, then 6th should succeed
      Crucible.Bulkhead.release(tenant)
      assert :ok = Crucible.Bulkhead.acquire(tenant)

      # Cleanup
      for _ <- 1..5, do: Crucible.Bulkhead.release(tenant)
    end
  end
end
