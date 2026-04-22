defmodule Crucible.Utils.GroupByTest do
  use ExUnit.Case, async: true

  alias Crucible.Utils.GroupBy

  # ---------------------------------------------------------------------------
  # group_by/2
  # ---------------------------------------------------------------------------

  describe "group_by/2" do
    test "groups items by key function result" do
      items = [%{x: 1}, %{x: 2}, %{x: 1}]
      assert GroupBy.group_by(items, & &1.x) == %{1 => [%{x: 1}, %{x: 1}], 2 => [%{x: 2}]}
    end

    test "returns empty map for empty collection" do
      assert GroupBy.group_by([], & &1) == %{}
    end

    test "maps nil keys to :unknown" do
      items = [%{x: nil}, %{x: "a"}]
      result = GroupBy.group_by(items, & &1.x)
      assert Map.get(result, :unknown) == [%{x: nil}]
      assert Map.get(result, "a") == [%{x: "a"}]
    end

    test "preserves insertion order within each group" do
      items = [%{k: :a, v: 1}, %{k: :b, v: 2}, %{k: :a, v: 3}]
      result = GroupBy.group_by(items, & &1.k)
      assert result[:a] == [%{k: :a, v: 1}, %{k: :a, v: 3}]
    end

    test "handles a single item" do
      assert GroupBy.group_by([%{status: "done"}], & &1.status) == %{
               "done" => [%{status: "done"}]
             }
    end
  end
end
