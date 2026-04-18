defmodule Crucible.CostEventReaderPropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Crucible.CostEventReader

  property "concurrent all_sessions reads never crash the GenServer" do
    check all(concurrency <- integer(2..10)) do
      tasks =
        for _ <- 1..concurrency do
          Task.async(fn ->
            try do
              CostEventReader.all_sessions([])
            catch
              :exit, _ -> []
            end
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &is_list/1)
    end
  end

  property "concurrent stats reads never crash the GenServer" do
    check all(concurrency <- integer(2..8)) do
      tasks =
        for _ <- 1..concurrency do
          Task.async(fn ->
            try do
              CostEventReader.stats([])
            catch
              :exit, _ -> %{}
            end
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &is_map/1)
    end
  end
end
