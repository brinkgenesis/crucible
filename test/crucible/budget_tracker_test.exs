defmodule Crucible.BudgetTrackerTest do
  use ExUnit.Case, async: true

  alias Crucible.BudgetTracker

  setup do
    # Each test gets its own BudgetTracker with a unique ETS table name
    # Since BudgetTracker uses a named table, we need to stop the app-level one
    # and start our own. For now, test against the globally started one.
    :ok
  end

  describe "daily_status/0" do
    test "returns budget status with default limits" do
      status = BudgetTracker.daily_status()
      assert is_float(status.spent)
      assert is_float(status.remaining)
      assert is_boolean(status.exceeded?)
    end

    test "tracks recorded costs" do
      BudgetTracker.record_cost("test-agent", 1.50)
      # Give the cast time to process
      Process.sleep(50)

      status = BudgetTracker.daily_status()
      assert status.spent >= 1.50
    end
  end

  describe "agent_status/1" do
    test "returns zero for unknown agent" do
      status = BudgetTracker.agent_status("nonexistent-agent")
      assert status.spent == 0.0
      assert status.exceeded? == false
    end

    test "tracks per-agent costs" do
      BudgetTracker.record_cost("agent-tier-test", 5.0)
      Process.sleep(50)

      status = BudgetTracker.agent_status("agent-tier-test")
      assert status.spent >= 5.0
    end

    test "returns correct remaining budget" do
      BudgetTracker.record_cost("agent-remaining-test", 3.0)
      Process.sleep(50)

      status = BudgetTracker.agent_status("agent-remaining-test")
      # Default agent limit is 10.0
      assert status.remaining <= 7.0
    end
  end

  describe "task_status/1" do
    test "returns zero for unknown task" do
      status = BudgetTracker.task_status("nonexistent-task")
      assert status.spent == 0.0
      assert status.exceeded? == false
    end

    test "tracks per-task costs" do
      BudgetTracker.record_cost("agent-x", 25.0, task_id: "task-tier-test")
      Process.sleep(50)

      status = BudgetTracker.task_status("task-tier-test")
      assert status.spent >= 25.0
    end

    test "does not track task cost when task_id not provided" do
      BudgetTracker.record_cost("agent-no-task", 2.0)
      Process.sleep(50)

      status = BudgetTracker.task_status("should-not-exist")
      assert status.spent == 0.0
    end
  end

  describe "budget_check/2" do
    test "returns :ok when under all limits" do
      assert :ok = BudgetTracker.budget_check("fresh-agent")
    end

    test "returns :ok with task_id when under limits" do
      assert :ok = BudgetTracker.budget_check("fresh-agent-2", task_id: "fresh-task")
    end

    test "detects agent budget exceeded" do
      # Record enough to exceed the $10 agent limit
      BudgetTracker.record_cost("over-budget-agent", 11.0)
      Process.sleep(50)

      result = BudgetTracker.budget_check("over-budget-agent")
      assert {:exceeded, :agent, status} = result
      assert status.exceeded? == true
      assert status.spent >= 11.0
    end

    test "detects task budget exceeded" do
      # Record enough to exceed the $50 task limit
      BudgetTracker.record_cost("task-buster-agent", 51.0, task_id: "over-budget-task")
      Process.sleep(50)

      result = BudgetTracker.budget_check("task-buster-agent-2", task_id: "over-budget-task")
      assert {:exceeded, :task, status} = result
      assert status.exceeded? == true
      assert status.spent >= 51.0
    end
  end

  describe "record_cost/3 backward compatibility" do
    test "record_cost/2 still works (no opts)" do
      BudgetTracker.record_cost("compat-agent", 1.0)
      Process.sleep(50)

      status = BudgetTracker.agent_status("compat-agent")
      assert status.spent >= 1.0
    end
  end
end
