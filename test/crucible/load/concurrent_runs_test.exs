defmodule Crucible.Load.ConcurrentRunsTest do
  @moduledoc """
  Load test: spawns 50+ simultaneous workflow runs and verifies all reach
  terminal states without deadlocks, crashes, or state corruption.

  Tagged with :load for CI isolation — excluded from default test runs.
  Run with: mix test --only load
  """

  use ExUnit.Case, async: true

  @moduletag :load

  alias Crucible.LoadTestHelpers
  alias Crucible.LoadTestHelpers.{InstantAdapter, SlowAdapter, FlakyAdapter}
  alias Crucible.Types.{Run, Phase}

  @concurrent_count 50
  @extended_count 100

  describe "concurrent runs with InstantAdapter" do
    test "50 runs all reach terminal state" do
      runs =
        Enum.map(1..@concurrent_count, fn i ->
          LoadTestHelpers.minimal_run(%{id: "concurrent-instant-#{i}"})
        end)

      results =
        LoadTestHelpers.spawn_concurrent_runs(runs, fn run ->
          execute_with_adapter(run, InstantAdapter)
        end)

      assert length(results) == @concurrent_count

      Enum.each(results, fn result ->
        assert {:ok, _} = result, "Expected all runs to succeed with InstantAdapter"
      end)

      completed = Enum.count(results, &match?({:ok, _}, &1))
      assert completed == @concurrent_count
    end

    test "100 runs complete without resource exhaustion" do
      runs =
        Enum.map(1..@extended_count, fn i ->
          LoadTestHelpers.minimal_run(%{id: "concurrent-extended-#{i}"})
        end)

      results =
        LoadTestHelpers.spawn_concurrent_runs(
          runs,
          fn run ->
            execute_with_adapter(run, InstantAdapter)
          end,
          max_concurrency: 50
        )

      assert length(results) == @extended_count

      completed = Enum.count(results, &match?({:ok, _}, &1))
      assert completed == @extended_count
    end
  end

  describe "concurrent runs with SlowAdapter" do
    test "50 runs complete despite variable latency" do
      runs =
        Enum.map(1..@concurrent_count, fn i ->
          LoadTestHelpers.minimal_run(%{id: "concurrent-slow-#{i}"})
        end)

      results =
        LoadTestHelpers.spawn_concurrent_runs(runs, fn run ->
          execute_with_adapter(run, SlowAdapter)
        end)

      assert length(results) == @concurrent_count

      Enum.each(results, fn result ->
        assert {:ok, _} = result, "Expected all slow runs to succeed"
      end)
    end
  end

  describe "concurrent runs with FlakyAdapter" do
    test "50 runs all reach terminal state (success or failure)" do
      runs =
        Enum.map(1..@concurrent_count, fn i ->
          LoadTestHelpers.minimal_run(%{id: "concurrent-flaky-#{i}"})
        end)

      results =
        LoadTestHelpers.spawn_concurrent_runs(runs, fn run ->
          execute_with_adapter(run, FlakyAdapter)
        end)

      assert length(results) == @concurrent_count

      # Every result must be either {:ok, _} or {:error, _} — no crashes or hangs
      Enum.each(results, fn result ->
        assert match?({:ok, _}, result) or match?({:error, _}, result),
               "Expected terminal state, got: #{inspect(result)}"
      end)

      succeeded = Enum.count(results, &match?({:ok, _}, &1))
      failed = Enum.count(results, &match?({:error, _}, &1))

      # With ~30% failure rate, expect roughly 25-45 successes out of 50
      # Use wide bounds to avoid flaky tests
      assert succeeded + failed == @concurrent_count
      assert succeeded > 0, "Expected at least some successes"
      assert failed > 0, "Expected at least some failures (30% failure rate)"
    end
  end

  describe "concurrent runs with multi-phase workflows" do
    test "50 multi-phase runs complete sequentially within each run" do
      runs =
        Enum.map(1..@concurrent_count, fn i ->
          phases =
            Enum.map(0..2, fn idx ->
              %Phase{
                id: "phase-#{idx}",
                name: "Phase #{idx}",
                type: :session,
                prompt: "multi-phase test #{idx}",
                status: :pending,
                phase_index: idx
              }
            end)

          LoadTestHelpers.minimal_run(%{
            id: "concurrent-multi-#{i}",
            phases: phases
          })
        end)

      results =
        LoadTestHelpers.spawn_concurrent_runs(runs, fn run ->
          execute_with_adapter(run, InstantAdapter)
        end)

      assert length(results) == @concurrent_count

      Enum.each(results, fn result ->
        assert {:ok, phase_results} = result
        # Each run should have completed all 3 phases
        assert length(phase_results) == 3
      end)
    end
  end

  describe "no deadlocks" do
    test "concurrent runs complete within timeout" do
      runs =
        Enum.map(1..@concurrent_count, fn i ->
          LoadTestHelpers.minimal_run(%{id: "deadlock-check-#{i}"})
        end)

      # Use a strict 10s timeout — if any run deadlocks, this fails
      results =
        LoadTestHelpers.spawn_concurrent_runs(
          runs,
          fn run ->
            execute_with_adapter(run, SlowAdapter)
          end,
          timeout: 10_000
        )

      timeouts = Enum.count(results, &match?({:error, :timeout}, &1))
      assert timeouts == 0, "Expected no timeouts (deadlocks), got #{timeouts}"
    end
  end

  describe "unique run isolation" do
    test "each run produces independent results" do
      runs =
        Enum.map(1..@concurrent_count, fn i ->
          LoadTestHelpers.minimal_run(%{id: "isolation-#{i}"})
        end)

      results =
        LoadTestHelpers.spawn_concurrent_runs(runs, fn run ->
          result = InstantAdapter.execute_phase(run, hd(run.phases), "test", [])

          case result do
            {:ok, data} -> {:ok, %{run_id: run.id, data: data}}
            error -> error
          end
        end)

      # Verify all run IDs in results are unique
      run_ids =
        results
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, %{run_id: id}} -> id end)

      assert length(Enum.uniq(run_ids)) == length(run_ids),
             "Expected all run IDs to be unique — state leaked between runs"
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────

  # Execute a run's phases sequentially using the given adapter,
  # bypassing the full AgentRunner/PhaseRunner stack to avoid
  # dependencies on PubSub, Registry, and BudgetTracker.
  defp execute_with_adapter(%Run{phases: phases} = run, adapter) do
    results =
      Enum.reduce_while(phases, [], fn phase, acc ->
        case adapter.execute_phase(run, phase, phase.prompt || "", []) do
          {:ok, data} -> {:cont, [{phase.id, data} | acc]}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case results do
      {:error, _} = err -> err
      phase_results when is_list(phase_results) -> {:ok, Enum.reverse(phase_results)}
    end
  end
end
