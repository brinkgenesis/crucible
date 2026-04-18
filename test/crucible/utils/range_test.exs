defmodule Crucible.Utils.RangeTest do
  use ExUnit.Case, async: true

  alias Crucible.Utils.Range, as: R

  # ---------------------------------------------------------------------------
  # range/3
  # ---------------------------------------------------------------------------

  describe "range/3" do
    test "generates an inclusive ascending sequence with default step" do
      assert R.range(1, 5) == [1, 2, 3, 4, 5]
    end

    test "respects a custom step" do
      assert R.range(0, 10, 2) == [0, 2, 4, 6, 8, 10]
    end

    test "generates a descending sequence with negative step" do
      assert R.range(5, 1, -1) == [5, 4, 3, 2, 1]
    end

    test "returns a single-element list when start equals stop" do
      assert R.range(3, 3) == [3]
    end

    test "returns empty list when step is zero" do
      assert R.range(1, 5, 0) == []
    end

    test "returns empty list when ascending step cannot reach stop" do
      assert R.range(5, 1, 1) == []
    end

    test "returns empty list when descending step cannot reach stop" do
      assert R.range(1, 5, -1) == []
    end

    test "works with float step" do
      assert R.range(0.0, 1.0, 0.5) == [0.0, 0.5, 1.0]
    end
  end

  # ---------------------------------------------------------------------------
  # clamp/3
  # ---------------------------------------------------------------------------

  describe "clamp/3" do
    test "returns value when within bounds" do
      assert R.clamp(5, 1, 10) == 5
    end

    test "clamps to min when below" do
      assert R.clamp(-1, 0, 100) == 0
    end

    test "clamps to max when above" do
      assert R.clamp(200, 0, 100) == 100
    end

    test "clamps float to max" do
      assert R.clamp(150.0, 0.0, 100.0) == 100.0
    end

    test "returns min when min equals max" do
      assert R.clamp(50, 42, 42) == 42
    end
  end

  # ---------------------------------------------------------------------------
  # chunk_range/2
  # ---------------------------------------------------------------------------

  describe "chunk_range/2" do
    test "splits evenly divisible total into equal chunks" do
      result = R.chunk_range(100, 25)
      assert result == [{0, 25}, {25, 25}, {50, 25}, {75, 25}]
    end

    test "produces a smaller final chunk for non-divisible totals" do
      result = R.chunk_range(55, 25)
      assert length(result) == 3
      assert List.last(result) == {50, 5}
    end

    test "returns single chunk when total fits in one page" do
      assert R.chunk_range(10, 50) == [{0, 10}]
    end

    test "returns empty list for zero or negative total" do
      assert R.chunk_range(0, 25) == []
      assert R.chunk_range(-1, 25) == []
    end

    test "returns empty list for non-positive chunk size" do
      assert R.chunk_range(100, 0) == []
      assert R.chunk_range(100, -1) == []
    end
  end
end
