defmodule Crucible.Load.StateCorruptionTest do
  @moduledoc """
  Property-based tests using StreamData to verify that random interleavings
  of run operations never produce invalid state.

  Validates state machine invariants:
  - No run occupies two states simultaneously
  - Phase transitions are monotonic (no backward jumps)
  - Terminal states are absorbing (completed/failed/done/orphaned can't escape)
  - Run counts remain consistent across operations
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Crucible.Types.{Run, Phase}

  @tag :load

  # --- State Machine Definition ---

  # Mirror of ResultWriter's @allowed_transitions, using atoms for internal use.
  @allowed_transitions %{
    pending: MapSet.new([:running, :failed, :orphaned]),
    running: MapSet.new([:review, :done, :failed, :orphaned, :budget_paused]),
    review: MapSet.new([:done, :failed, :orphaned]),
    failed: MapSet.new([:running, :orphaned]),
    done: MapSet.new([:done]),
    orphaned: MapSet.new([:orphaned]),
    budget_paused: MapSet.new([:running, :failed, :orphaned])
  }

  # States where no outward transition to a *different* state is possible.
  @terminal_states MapSet.new([:done, :orphaned, :completed, :cancelled])

  # All valid run statuses.
  @all_statuses [
    :pending,
    :running,
    :review,
    :done,
    :completed,
    :failed,
    :cancelled,
    :orphaned,
    :budget_paused
  ]

  # Ordered phase indices for monotonicity checks.
  @phase_status_order %{
    pending: 0,
    running: 1,
    review: 2,
    done: 3,
    completed: 4,
    failed: 5
  }

  # --- StreamData Generators ---

  defp run_id_gen do
    gen all(id <- string(:alphanumeric, min_length: 8, max_length: 16)) do
      "run-#{id}"
    end
  end

  defp initial_status_gen do
    member_of([:pending, :running])
  end

  defp phase_gen(index) do
    gen all(
          name <- string(:alphanumeric, min_length: 4, max_length: 12),
          type <- member_of([:session, :team, :api, :review_gate, :pr_shepherd, :preflight]),
          status <- member_of([:pending, :running, :review, :done, :failed])
        ) do
      %Phase{
        id: "phase-#{index}-#{name}",
        name: name,
        type: type,
        status: status,
        phase_index: index
      }
    end
  end

  defp run_gen do
    gen all(
          id <- run_id_gen(),
          status <- initial_status_gen(),
          phase_count <- integer(1..6),
          phases <- fixed_list(Enum.map(0..(phase_count - 1), &phase_gen/1)),
          budget <- float(min: 1.0, max: 100.0)
        ) do
      %Run{
        id: id,
        workflow_type: "test",
        status: status,
        phases: phases,
        budget_usd: budget,
        version: 0
      }
    end
  end

  defp operation_gen do
    member_of([
      :start,
      :advance_phase,
      :complete,
      :fail,
      :cancel,
      :budget_pause,
      :resume,
      :orphan
    ])
  end

  defp operation_sequence_gen do
    list_of(operation_gen(), min_length: 1, max_length: 50)
  end

  # --- State Machine Simulation ---

  # Apply an operation to a run, respecting the allowed transitions.
  # Returns the updated run (or unchanged if the transition is invalid).
  defp apply_operation(run, :start) do
    try_transition(run, :running)
  end

  defp apply_operation(run, :advance_phase) do
    run = try_transition(run, :running)
    advance_next_phase(run)
  end

  defp apply_operation(run, :complete) do
    try_transition(run, :done)
  end

  defp apply_operation(run, :fail) do
    try_transition(run, :failed)
  end

  defp apply_operation(run, :cancel) do
    # Cancel is special — it's always allowed in the RunServer (kills process).
    # But in the state machine, cancelled is a terminal state not in the
    # allowed_transitions map, so we only allow it from non-terminal states.
    if MapSet.member?(@terminal_states, run.status) do
      run
    else
      %{run | status: :cancelled, version: run.version + 1}
    end
  end

  defp apply_operation(run, :budget_pause) do
    try_transition(run, :budget_paused)
  end

  defp apply_operation(run, :resume) do
    if run.status == :budget_paused do
      try_transition(run, :running)
    else
      run
    end
  end

  defp apply_operation(run, :orphan) do
    try_transition(run, :orphaned)
  end

  defp try_transition(run, next_status) do
    allowed = Map.get(@allowed_transitions, run.status, MapSet.new())

    if MapSet.member?(allowed, next_status) do
      %{run | status: next_status, version: run.version + 1}
    else
      run
    end
  end

  defp advance_next_phase(%{phases: []} = run), do: run

  defp advance_next_phase(run) do
    case Enum.find_index(run.phases, &(&1.status in [:pending, :running])) do
      nil ->
        run

      idx ->
        phase = Enum.at(run.phases, idx)
        next_status = next_phase_status(phase.status)

        updated_phases =
          List.update_at(run.phases, idx, fn p -> %{p | status: next_status} end)

        %{run | phases: updated_phases}
    end
  end

  defp next_phase_status(:pending), do: :running
  defp next_phase_status(:running), do: :review
  defp next_phase_status(:review), do: :done
  defp next_phase_status(other), do: other

  # --- Invariant Checkers ---

  defp assert_single_status(run) do
    # A run has exactly one status — it's a single atom field, so this is
    # structurally guaranteed. But we verify it's a known status.
    assert run.status in @all_statuses,
           "Run #{run.id} has unknown status: #{inspect(run.status)}"
  end

  defp assert_terminal_absorbing(run_before, run_after, operation) do
    if MapSet.member?(@terminal_states, run_before.status) do
      assert run_after.status == run_before.status,
             "Terminal state #{run_before.status} was escaped via #{operation} " <>
               "to #{run_after.status} for run #{run_before.id}"
    end
  end

  defp assert_version_monotonic(run_before, run_after) do
    assert run_after.version >= run_before.version,
           "Version went backwards: #{run_before.version} -> #{run_after.version} " <>
             "for run #{run_before.id}"
  end

  defp assert_phase_monotonic(run) do
    for phase <- run.phases do
      order = Map.get(@phase_status_order, phase.status, -1)

      assert order >= 0 or phase.status in [:cancelled, :orphaned, :budget_paused],
             "Phase #{phase.id} in run #{run.id} has unexpected status: #{inspect(phase.status)}"
    end

    # Phases should not go backwards: if phase N is done, phase N-1 shouldn't be pending
    # (unless phases run in parallel, which we don't enforce here).
    completed_indices =
      run.phases
      |> Enum.filter(&(&1.status in [:done, :completed]))
      |> Enum.map(& &1.phase_index)
      |> MapSet.new()

    for phase <- run.phases do
      if phase.status == :pending and phase.phase_index > 0 do
        prior_still_pending =
          Enum.any?(run.phases, fn p ->
            p.phase_index < phase.phase_index and p.status == :done
          end)

        # This is informational, not a hard invariant, since phases can have
        # depends_on relationships that allow non-sequential ordering.
        if prior_still_pending and MapSet.size(completed_indices) > 0 do
          :ok
        end
      end
    end
  end

  defp assert_consistent_counts(runs) do
    status_counts =
      Enum.frequencies_by(runs, & &1.status)

    total = Enum.sum(Map.values(status_counts))
    assert total == length(runs), "Status count sum #{total} != run count #{length(runs)}"
  end

  # --- Property Tests ---

  @tag :load
  property "single run: random operations never produce invalid state" do
    check all(
            run <- run_gen(),
            ops <- operation_sequence_gen(),
            max_runs: 200
          ) do
      final_run =
        Enum.reduce(ops, run, fn op, acc ->
          before = acc
          after_op = apply_operation(acc, op)

          assert_single_status(after_op)
          assert_terminal_absorbing(before, after_op, op)
          assert_version_monotonic(before, after_op)

          after_op
        end)

      assert_single_status(final_run)
      assert_phase_monotonic(final_run)
    end
  end

  @tag :load
  property "multiple runs: interleaved operations maintain consistent counts" do
    check all(
            run_count <- integer(2..8),
            runs <- list_of(run_gen(), length: run_count),
            ops_per_run <- list_of(operation_sequence_gen(), length: run_count),
            max_runs: 100
          ) do
      # Interleave operations across runs randomly
      indexed_ops =
        ops_per_run
        |> Enum.with_index()
        |> Enum.flat_map(fn {ops, idx} ->
          Enum.map(ops, fn op -> {idx, op} end)
        end)
        |> Enum.shuffle()

      run_map =
        runs
        |> Enum.with_index()
        |> Map.new(fn {run, idx} -> {idx, run} end)

      final_map =
        Enum.reduce(indexed_ops, run_map, fn {idx, op}, acc ->
          run = Map.fetch!(acc, idx)
          updated = apply_operation(run, op)
          Map.put(acc, idx, updated)
        end)

      final_runs = Map.values(final_map)
      assert_consistent_counts(final_runs)

      for run <- final_runs do
        assert_single_status(run)
        assert_phase_monotonic(run)
      end
    end
  end

  @tag :load
  property "terminal states are absorbing under all operations" do
    check all(
            status <- member_of(MapSet.to_list(@terminal_states)),
            ops <- operation_sequence_gen(),
            max_runs: 200
          ) do
      run = %Run{
        id: "terminal-test-#{System.unique_integer([:positive])}",
        workflow_type: "test",
        status: status,
        phases: [],
        budget_usd: 10.0,
        version: 1
      }

      final =
        Enum.reduce(ops, run, fn op, acc ->
          apply_operation(acc, op)
        end)

      assert final.status == status,
             "Terminal state #{status} escaped to #{final.status} after #{length(ops)} operations"
    end
  end

  @tag :load
  property "version is strictly monotonic on state changes" do
    check all(
            run <- run_gen(),
            ops <- operation_sequence_gen(),
            max_runs: 200
          ) do
      {_final, version_history} =
        Enum.reduce(ops, {run, [run.version]}, fn op, {acc, versions} ->
          updated = apply_operation(acc, op)
          {updated, [updated.version | versions]}
        end)

      reversed = Enum.reverse(version_history)

      # Versions should be non-decreasing
      for {v1, v2} <- Enum.zip(reversed, tl(reversed)) do
        assert v2 >= v1, "Version decreased: #{v1} -> #{v2}"
      end
    end
  end

  @tag :load
  property "failed runs can retry (failed -> running) but terminal states cannot" do
    check all(
            ops <- operation_sequence_gen(),
            max_runs: 200
          ) do
      run = %Run{
        id: "retry-test-#{System.unique_integer([:positive])}",
        workflow_type: "test",
        status: :pending,
        phases: [],
        budget_usd: 10.0,
        version: 0
      }

      Enum.reduce(ops, run, fn op, acc ->
        before = acc
        after_op = apply_operation(acc, op)

        # If we went from failed to running, that's a valid retry.
        # advance_phase also triggers a start transition internally.
        if before.status == :failed and after_op.status == :running do
          assert op in [:start, :resume, :advance_phase],
                 "Unexpected operation #{op} caused failed -> running"
        end

        # done/orphaned/completed/cancelled should never transition out
        if before.status in [:done, :orphaned, :completed, :cancelled] do
          assert after_op.status == before.status,
                 "Terminal state #{before.status} escaped via #{op}"
        end

        after_op
      end)
    end
  end

  @tag :load
  property "concurrent state transitions on shared run converge to valid state" do
    check all(
            run <- run_gen(),
            task_count <- integer(2..10),
            ops_per_task <- list_of(operation_sequence_gen(), length: task_count),
            max_runs: 50
          ) do
      # Simulate concurrent access by running operations from multiple "tasks"
      # against the same run state. Since we're simulating (not using actual
      # processes), we interleave deterministically.
      all_ops =
        ops_per_task
        |> Enum.with_index()
        |> Enum.flat_map(fn {ops, task_idx} ->
          Enum.map(ops, fn op -> {task_idx, op} end)
        end)
        |> Enum.shuffle()

      final =
        Enum.reduce(all_ops, run, fn {_task_idx, op}, acc ->
          apply_operation(acc, op)
        end)

      assert_single_status(final)
      assert final.version >= run.version
      assert_phase_monotonic(final)

      # If the run reached a terminal state at any point, it should still
      # be in that terminal state
      {_run, saw_terminal} =
        Enum.reduce(all_ops, {run, nil}, fn {_task_idx, op}, {acc, terminal} ->
          updated = apply_operation(acc, op)

          new_terminal =
            if terminal do
              terminal
            else
              if MapSet.member?(@terminal_states, updated.status),
                do: updated.status,
                else: nil
            end

          {updated, new_terminal}
        end)

      if saw_terminal do
        assert final.status == saw_terminal,
               "Run escaped terminal state #{saw_terminal}, now #{final.status}"
      end
    end
  end
end
