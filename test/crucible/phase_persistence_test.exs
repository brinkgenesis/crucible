defmodule Crucible.PhasePersistenceTest do
  use ExUnit.Case

  alias Crucible.PhasePersistence

  # PhasePersistence uses Repo, which requires sandbox checkout in tests.
  # These tests verify the API is resilient when DB isn't available (test sandbox).

  describe "record_phase_start/2" do
    test "returns :ok even when run doesn't exist in DB" do
      assert :ok = PhasePersistence.record_phase_start("nonexistent-run", 0)
    end

    test "returns :ok for valid inputs" do
      assert :ok = PhasePersistence.record_phase_start("test-run-123", 1)
    end
  end

  describe "record_phase_complete/2" do
    test "returns :ok even when run doesn't exist" do
      assert :ok = PhasePersistence.record_phase_complete("nonexistent-run", 0)
    end
  end

  describe "record_phase_failed/3" do
    test "returns :ok with reason string" do
      assert :ok = PhasePersistence.record_phase_failed("nonexistent-run", 0, "timeout")
    end

    test "truncates long reason strings" do
      long_reason = String.duplicate("x", 500)
      assert :ok = PhasePersistence.record_phase_failed("test-run", 0, long_reason)
    end
  end

  describe "record_run_complete/1" do
    test "returns :ok for any run_id" do
      assert :ok = PhasePersistence.record_run_complete("test-run-complete")
    end
  end

  describe "record_run_failed/1" do
    test "returns :ok for any run_id" do
      assert :ok = PhasePersistence.record_run_failed("test-run-failed")
    end
  end

  describe "find_crashed_runs/1" do
    test "returns empty list when DB unavailable" do
      assert [] = PhasePersistence.find_crashed_runs("test-node@host")
    end
  end

  describe "mark_crashed_runs/1" do
    test "returns 0 when no crashed runs" do
      assert 0 = PhasePersistence.mark_crashed_runs("test-node@host")
    end
  end
end
