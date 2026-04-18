defmodule Crucible.StatusTest do
  use ExUnit.Case, async: true

  alias Crucible.Status

  describe "to_atom/1" do
    test "maps known statuses to canonical atoms" do
      assert Status.to_atom("pending") == :pending
      assert Status.to_atom("running") == :running
      assert Status.to_atom("in_progress") == :running
      assert Status.to_atom("done") == :done
      assert Status.to_atom("completed") == :done
      assert Status.to_atom("failed") == :failed
      assert Status.to_atom("cancelled") == :cancelled
      assert Status.to_atom("orphaned") == :orphaned
      assert Status.to_atom("review") == :review
      assert Status.to_atom("budget_paused") == :budget_paused
      assert Status.to_atom("timeout") == :timeout
    end

    test "returns :unknown for unrecognized strings" do
      assert Status.to_atom("evil_payload") == :unknown
      assert Status.to_atom("") == :unknown
      assert Status.to_atom("RUNNING") == :unknown
      assert Status.to_atom("Running") == :unknown
    end

    test "returns :unknown for nil" do
      assert Status.to_atom(nil) == :unknown
    end

    test "returns :unknown for non-string values" do
      assert Status.to_atom(42) == :unknown
      assert Status.to_atom(:running) == :unknown
      assert Status.to_atom(%{}) == :unknown
    end

    test "does not create new atoms" do
      # This is the whole point — arbitrary strings must not become atoms
      random = "random_#{:crypto.strong_rand_bytes(8) |> Base.hex_encode32()}"
      assert Status.to_atom(random) == :unknown
    end
  end

  describe "known_strings/0" do
    test "returns all recognized status strings" do
      strings = Status.known_strings()
      assert "pending" in strings
      assert "running" in strings
      assert "done" in strings
      assert "failed" in strings
      assert length(strings) > 0
    end
  end

  describe "known_atoms/0" do
    test "returns deduplicated canonical atoms" do
      atoms = Status.known_atoms()
      assert :pending in atoms
      assert :running in atoms
      assert :done in atoms
      # Verify dedup: :running appears once even though "running" and "in_progress" map to it
      assert length(Enum.filter(atoms, &(&1 == :running))) == 1
    end
  end
end
