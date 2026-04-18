defmodule Crucible.ExternalCircuitBreakerTest do
  use ExUnit.Case, async: false

  alias Crucible.ExternalCircuitBreaker

  setup do
    # Reset state before each test
    if pid = Process.whereis(ExternalCircuitBreaker) do
      # Replace state via sys call (GenServer-compatible)
      :sys.replace_state(pid, fn _ -> %{} end)
    end

    :ok
  end

  describe "check/1" do
    test "allows requests on fresh circuit" do
      assert :ok = ExternalCircuitBreaker.check(:test_service)
    end

    test "opens after 3 consecutive failures" do
      ExternalCircuitBreaker.record_failure(:failing_svc)
      ExternalCircuitBreaker.record_failure(:failing_svc)
      ExternalCircuitBreaker.record_failure(:failing_svc)

      assert {:blocked, _reason} = ExternalCircuitBreaker.check(:failing_svc)
    end
  end

  describe "record_success/1" do
    test "resets circuit after failures" do
      ExternalCircuitBreaker.record_failure(:reset_svc)
      ExternalCircuitBreaker.record_failure(:reset_svc)
      ExternalCircuitBreaker.record_success(:reset_svc)

      assert :ok = ExternalCircuitBreaker.check(:reset_svc)
    end
  end

  describe "status/0" do
    test "returns map of all breaker states" do
      ExternalCircuitBreaker.check(:status_svc)
      status = ExternalCircuitBreaker.status()
      assert is_map(status)
      assert Map.has_key?(status, :status_svc)
    end
  end
end
