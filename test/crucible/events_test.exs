defmodule Crucible.EventsTest do
  use ExUnit.Case, async: true

  alias Crucible.Events

  describe "team events" do
    test "subscribe and receive team_update" do
      team = "test-team-#{:rand.uniform(10000)}"
      Events.subscribe_team(team)

      snapshot = %{total: 2, completed: 1, all_completed: false}
      Events.broadcast_team_update(team, snapshot)

      assert_receive {:team_update, ^team, ^snapshot}
    end

    test "subscribe and receive team_completed" do
      team = "test-team-#{:rand.uniform(10000)}"
      Events.subscribe_team(team)

      snapshot = %{total: 2, completed: 2, all_completed: true}
      Events.broadcast_team_completed(team, snapshot)

      assert_receive {:team_completed, ^team, ^snapshot}
    end

    test "does not receive events for other teams" do
      team_a = "team-a-#{:rand.uniform(10000)}"
      team_b = "team-b-#{:rand.uniform(10000)}"
      Events.subscribe_team(team_a)

      Events.broadcast_team_update(team_b, %{})

      refute_receive {:team_update, _, _}
    end
  end

  describe "run events" do
    test "subscribe and receive run events" do
      run_id = "run-#{:rand.uniform(10000)}"
      Events.subscribe_run(run_id)

      Events.broadcast_run_event(run_id, :started, %{workflow_type: "test"})

      assert_receive {:run_event, ^run_id, :started, %{workflow_type: "test"}}
    end
  end

  describe "phase events" do
    test "subscribe and receive phase events" do
      run_id = "run-#{:rand.uniform(10000)}"
      phase_id = "phase-0"
      Events.subscribe_phase(run_id, phase_id)

      Events.broadcast_phase_event(run_id, phase_id, :completed, %{})

      assert_receive {:phase_event, ^run_id, ^phase_id, :completed, %{}}
    end

    test "does not receive events for other phases" do
      run_id = "run-#{:rand.uniform(10000)}"
      Events.subscribe_phase(run_id, "phase-0")

      Events.broadcast_phase_event(run_id, "phase-1", :completed, %{})

      refute_receive {:phase_event, _, _, _, _}
    end
  end
end
