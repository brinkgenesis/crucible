defmodule Crucible.WorkflowStoreTest do
  use ExUnit.Case, async: true

  alias Crucible.WorkflowStore

  describe "get/1 and list/0" do
    test "returns not_found for unknown workflow" do
      assert {:error, :not_found} = WorkflowStore.get("nonexistent-workflow")
    end

    test "list returns loaded workflow names" do
      names = WorkflowStore.list()
      assert is_list(names)
    end
  end
end
