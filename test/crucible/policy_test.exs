defmodule Crucible.PolicyTest do
  use ExUnit.Case, async: true

  alias Crucible.Policy

  describe "default_state" do
    test "load_state returns defaults when no file exists" do
      state = Policy.load_state("/nonexistent/path")
      assert state.active.policy_id == "default"
      assert state.active.timings.phase_poll_ms == 2_000
      assert state.active.timings.pickup_timeout_ms == 30_000
      assert state.active.timings.phase_timeout_ms == 600_000
      assert state.candidate == nil
      assert state.canary.min_runs == 12
    end
  end

  describe "save_state and load_state" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "policy_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, infra_home: tmp}
    end

    test "round-trips state", %{infra_home: home} do
      state = Policy.load_state(home)
      assert :ok = Policy.save_state(home, state)
      loaded = Policy.load_state(home)
      assert loaded.active.policy_id == state.active.policy_id
      assert loaded.active.timings == state.active.timings
    end
  end

  describe "resolve_run_policy" do
    test "returns active policy when no candidate" do
      state = Policy.load_state("/nonexistent")
      result = Policy.resolve_run_policy(state, "test-run-123")
      assert result.variant == :active
      assert result.canary == false
      assert result.timings.phase_poll_ms == 2_000
    end

    test "deterministic bucketing returns same result for same run_id" do
      state = Policy.load_state("/nonexistent")
      r1 = Policy.resolve_run_policy(state, "run-abc")
      r2 = Policy.resolve_run_policy(state, "run-abc")
      assert r1 == r2
    end

    test "routes some runs to candidate when enabled" do
      state = Policy.load_state("/nonexistent")

      candidate = %{
        policy_id: "candidate-1",
        created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        reason: "test",
        timings: %{phase_poll_ms: 1_000, pickup_timeout_ms: 25_000, phase_timeout_ms: 500_000},
        enabled: true,
        rollout_percent: 50
      }

      state = %{state | candidate: candidate}

      # With 50% rollout, sampling many runs should hit both
      results =
        Enum.map(1..100, fn i ->
          Policy.resolve_run_policy(state, "run-#{i}").variant
        end)

      assert :active in results
      assert :candidate in results
    end
  end

  describe "decide_candidate_action" do
    test "creates candidate when timeout rate is high" do
      state = Policy.load_state("/nonexistent")

      kpi = %{
        totals: %{
          timeout_rate: 0.15,
          fail_rate: 0.02,
          pickup_p95_ms: 4000,
          runs: 20,
          done: 17,
          failed: 0,
          orphaned: 3,
          timeout_runs: 3,
          force_completed_runs: 0,
          force_completed_rate: 0.0,
          total_cost: 10.0,
          avg_retries: 0.5
        },
        by_variant: %{active: %{runs: 20}, candidate: %{runs: 0}}
      }

      {new_state, action} = Policy.decide_candidate_action(state, kpi)
      assert action != nil
      assert action.type == :candidate_created
      assert new_state.candidate != nil
      assert new_state.candidate.timings.phase_timeout_ms > state.active.timings.phase_timeout_ms
    end

    test "returns nil action when metrics are healthy" do
      state = Policy.load_state("/nonexistent")

      kpi = %{
        totals: %{
          timeout_rate: 0.02,
          fail_rate: 0.01,
          pickup_p95_ms: 1000,
          runs: 20,
          done: 19,
          failed: 0,
          orphaned: 1,
          timeout_runs: 0,
          force_completed_runs: 0,
          force_completed_rate: 0.0,
          total_cost: 10.0,
          avg_retries: 0.1
        },
        by_variant: %{active: %{runs: 20}, candidate: %{runs: 0}}
      }

      {_new_state, action} = Policy.decide_candidate_action(state, kpi)
      assert action == nil
    end

    test "rolls back underperforming candidate" do
      state = Policy.load_state("/nonexistent")

      state = %{
        state
        | candidate: %{
            policy_id: "bad-candidate",
            created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            reason: "test",
            timings: %{phase_poll_ms: 1000, pickup_timeout_ms: 25000, phase_timeout_ms: 500_000},
            enabled: true,
            rollout_percent: 10
          }
      }

      kpi = %{
        totals: %{runs: 30},
        by_variant: %{
          active: %{runs: 15, fail_rate: 0.05, timeout_rate: 0.05, pickup_p95_ms: 2000},
          candidate: %{runs: 15, fail_rate: 0.20, timeout_rate: 0.15, pickup_p95_ms: 3000}
        }
      }

      {new_state, action} = Policy.decide_candidate_action(state, kpi)
      assert action.type == :candidate_rollback
      assert new_state.candidate == nil
      assert new_state.last_rollback != nil
    end

    test "promotes outperforming candidate" do
      state = Policy.load_state("/nonexistent")

      state = %{
        state
        | candidate: %{
            policy_id: "good-candidate",
            created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            reason: "test",
            timings: %{phase_poll_ms: 1000, pickup_timeout_ms: 25000, phase_timeout_ms: 750_000},
            enabled: true,
            rollout_percent: 10
          }
      }

      kpi = %{
        totals: %{runs: 30},
        by_variant: %{
          active: %{runs: 15, fail_rate: 0.10, timeout_rate: 0.15, pickup_p95_ms: 5000},
          candidate: %{runs: 15, fail_rate: 0.08, timeout_rate: 0.05, pickup_p95_ms: 3000}
        }
      }

      {new_state, action} = Policy.decide_candidate_action(state, kpi)
      assert action.type == :candidate_promoted
      assert new_state.candidate == nil
      assert new_state.active.policy_id == "good-candidate"
      assert new_state.last_promotion != nil
    end

    test "waits when not enough samples" do
      state = Policy.load_state("/nonexistent")

      state = %{
        state
        | candidate: %{
            policy_id: "new-candidate",
            created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            reason: "test",
            timings: %{phase_poll_ms: 1000, pickup_timeout_ms: 25000, phase_timeout_ms: 500_000},
            enabled: true,
            rollout_percent: 10
          }
      }

      kpi = %{
        totals: %{runs: 10},
        by_variant: %{
          active: %{runs: 5, fail_rate: 0.10, timeout_rate: 0.10, pickup_p95_ms: 2000},
          candidate: %{runs: 5, fail_rate: 0.20, timeout_rate: 0.15, pickup_p95_ms: 3000}
        }
      }

      {_new_state, action} = Policy.decide_candidate_action(state, kpi)
      assert action == nil
    end
  end

  describe "sanitize_timings" do
    test "clamps values to safe ranges" do
      timings =
        Policy.sanitize_timings(%{
          phase_poll_ms: 10,
          pickup_timeout_ms: 100,
          phase_timeout_ms: 99_999_999
        })

      assert timings.phase_poll_ms == 100
      assert timings.pickup_timeout_ms == 5_000
      assert timings.phase_timeout_ms == 14_400_000
    end

    test "preserves values within range" do
      timings =
        Policy.sanitize_timings(%{
          phase_poll_ms: 2000,
          pickup_timeout_ms: 30_000,
          phase_timeout_ms: 600_000
        })

      assert timings == %{
               phase_poll_ms: 2000,
               pickup_timeout_ms: 30_000,
               phase_timeout_ms: 600_000
             }
    end
  end
end
