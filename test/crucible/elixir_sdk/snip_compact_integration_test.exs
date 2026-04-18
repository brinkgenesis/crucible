defmodule Crucible.ElixirSdk.SnipCompactIntegrationTest do
  @moduledoc """
  Tests the SnipCompact integration contract used in Query.handle_tool_use_turn/1.

  Validates that the data transformation from raw tool results through
  SnipCompact and back to API format produces valid tool_result messages.
  """
  use ExUnit.Case, async: true

  alias Crucible.Context.SnipCompact

  describe "tool result compaction pipeline" do
    test "short results pass through with correct API format" do
      raw = [
        %{tool_use_id: "tu_1", tool_name: "read_file", content: "hello world"},
        %{tool_use_id: "tu_2", tool_name: "run_command", content: "ok"}
      ]

      %{results: compacted, total_saved: saved} = SnipCompact.snip_compact_tool_results(raw)

      assert saved == 0

      api_results =
        Enum.map(compacted, fn entry ->
          %{
            "type" => "tool_result",
            "tool_use_id" => entry.tool_use_id,
            "content" => entry.content
          }
        end)

      assert length(api_results) == 2
      assert Enum.at(api_results, 0)["tool_use_id"] == "tu_1"
      assert Enum.at(api_results, 0)["content"] == "hello world"
      assert Enum.at(api_results, 1)["tool_use_id"] == "tu_2"
    end

    test "large tool outputs get compacted" do
      big_output = String.duplicate("line of code output\n", 5_000)

      raw = [
        %{tool_use_id: "tu_big", tool_name: "run_command", content: big_output}
      ]

      %{results: compacted, total_saved: saved} = SnipCompact.snip_compact_tool_results(raw)

      assert saved > 0

      [entry] = compacted
      assert entry.tool_use_id == "tu_big"
      assert byte_size(entry.content) < byte_size(big_output)
    end

    test "exempt tools bypass compaction even when large" do
      big_output = String.duplicate("x ", 5_000)

      raw = [
        %{tool_use_id: "tu_edit", tool_name: "edit_file", content: big_output},
        %{tool_use_id: "tu_write", tool_name: "write_file", content: big_output}
      ]

      %{results: compacted, total_saved: saved} = SnipCompact.snip_compact_tool_results(raw)

      assert saved == 0

      for entry <- compacted do
        assert entry.content == big_output
      end
    end

    test "error results bypass compaction" do
      big_output = String.duplicate("error trace line\n", 5_000)

      raw = [
        %{tool_use_id: "tu_err", tool_name: "run_command", content: big_output, is_error: true}
      ]

      %{results: compacted, total_saved: saved} = SnipCompact.snip_compact_tool_results(raw)

      assert saved == 0
      [entry] = compacted
      assert entry.content == big_output
    end

    test "mixed results: some compacted, some exempt" do
      big_output = String.duplicate("verbose log line here\n", 5_000)

      raw = [
        %{tool_use_id: "tu_cmd", tool_name: "run_command", content: big_output},
        %{tool_use_id: "tu_edit", tool_name: "edit_file", content: big_output},
        %{tool_use_id: "tu_small", tool_name: "read_file", content: "short"}
      ]

      %{results: compacted, total_saved: saved} = SnipCompact.snip_compact_tool_results(raw)

      # run_command should be compacted (big), edit_file exempt (big but exempt), read_file pass-through (small)
      assert saved > 0
      assert length(compacted) == 3

      cmd_entry = Enum.find(compacted, &(&1.tool_use_id == "tu_cmd"))
      edit_entry = Enum.find(compacted, &(&1.tool_use_id == "tu_edit"))
      small_entry = Enum.find(compacted, &(&1.tool_use_id == "tu_small"))

      assert byte_size(cmd_entry.content) < byte_size(big_output)
      assert edit_entry.content == big_output
      assert small_entry.content == "short"
    end
  end
end
