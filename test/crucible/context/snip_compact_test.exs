defmodule Crucible.Context.SnipCompactTest do
  use ExUnit.Case, async: true

  alias Crucible.Context.SnipCompact

  describe "estimate_tokens/1" do
    test "empty string → 0" do
      assert SnipCompact.estimate_tokens("") == 0
      assert SnipCompact.estimate_tokens("   \n  ") == 0
    end

    test "grows roughly with input size" do
      short = SnipCompact.estimate_tokens("hello world")
      long = SnipCompact.estimate_tokens(String.duplicate("hello world ", 200))
      assert long > short * 50
    end
  end

  describe "snip_compact/2 threshold gate" do
    test "short content passes through unchanged" do
      result = SnipCompact.snip_compact("run_command", "hello")
      assert result.compacted == false
      assert result.content == "hello"
      assert result.original_tokens == result.compacted_tokens
    end

    test "exempt tools never compact, even when huge" do
      big = String.duplicate("x ", 5_000)

      for tool <- ~w(edit_file write_file git_commit memory_store) do
        result = SnipCompact.snip_compact(tool, big)
        assert result.compacted == false, "expected #{tool} to bypass compaction"
        assert result.content == big
      end
    end
  end

  describe "per-tool strategies" do
    test "run_command: long stdout gets head/tail snippet" do
      content = String.duplicate("line\n", 5_000)
      result = SnipCompact.snip_compact("run_command", content)

      assert result.compacted
      assert result.compacted_tokens < result.original_tokens
      assert result.content =~ "[snipCompact:"
      assert result.content =~ "--- first 300 chars ---"
      assert result.content =~ "--- last 200 chars ---"
      assert result.content =~ "chars omitted"
    end

    test "search_files: >20 result rows summarised with omission marker" do
      content =
        1..300
        |> Enum.map_join("\n", &"match #{&1} in some file with extra words to count")

      result = SnipCompact.snip_compact("search_files", content)

      assert result.compacted
      assert result.content =~ "300 results found"
      assert result.content =~ "--- ... 285 results omitted ---"
      assert result.content =~ "match 1 "
      assert result.content =~ "match 300 "
    end

    test "search_files: small result set returned verbatim" do
      small = "a\nb\nc"
      small_result = SnipCompact.snip_compact("search_files", small)
      assert small_result.compacted == false
      assert small_result.content == small
    end

    test "read_file: JSON-shaped payload surfaces path + line count" do
      file_contents =
        1..500
        |> Enum.map_join("\n", &"source line #{&1} with enough real words to count tokens")

      payload =
        Jason.encode!(%{
          "path" => "lib/example.ex",
          "content" => file_contents,
          "size_bytes" => byte_size(file_contents),
          "truncated" => false
        })

      result = SnipCompact.snip_compact("read_file", payload)

      assert result.compacted
      assert result.content =~ "File: lib/example.ex"
      assert result.content =~ "500 lines"
      assert result.content =~ "--- first 15 lines ---"
      assert result.content =~ "--- last 5 lines ---"
      assert result.content =~ "source line 1 "
      assert result.content =~ "source line 500 "
      refute result.content =~ "(file was truncated on read)"
    end

    test "read_file: truncated flag surfaces in summary" do
      file_contents =
        1..400 |> Enum.map_join("\n", &"line #{&1} with some actual words in it")

      payload =
        Jason.encode!(%{
          "path" => "lib/big.ex",
          "content" => file_contents,
          "truncated" => true
        })

      result = SnipCompact.snip_compact("read_file", payload)
      assert result.compacted
      assert result.content =~ "(file was truncated on read)"
    end

    test "read_file: non-JSON falls back to generic compaction" do
      raw = String.duplicate("not json at all ", 500)
      result = SnipCompact.snip_compact("read_file", raw)

      assert result.compacted
      assert result.content =~ "[snipCompact:"
      assert result.content =~ "content omitted"
    end

    test "unknown tool → generic compaction" do
      big = String.duplicate("payload ", 2_000)
      result = SnipCompact.snip_compact("some_random_tool", big)

      assert result.compacted
      assert result.content =~ "[snipCompact:"
      assert result.content =~ "content omitted"
    end
  end

  describe "snip_compact_tool_results/1" do
    test "error outputs are never compacted" do
      big_error = String.duplicate("stack trace line\n", 1_000)

      results = [
        %{
          tool_use_id: "1",
          tool_name: "run_command",
          content: big_error,
          is_error: true
        }
      ]

      %{results: [entry], total_saved: saved} = SnipCompact.snip_compact_tool_results(results)
      assert entry.content == big_error
      assert saved == 0
    end

    test "accumulates savings across multiple tool results" do
      big_cmd = String.duplicate("stdout row ", 2_000)

      big_search =
        1..400
        |> Enum.map_join("\n", &"hit #{&1} in file with enough words for tokens")

      small = "ok"

      results = [
        %{tool_use_id: "a", tool_name: "run_command", content: big_cmd},
        %{tool_use_id: "b", tool_name: "search_files", content: big_search},
        %{tool_use_id: "c", tool_name: "edit_file", content: small},
        %{tool_use_id: "d", tool_name: "write_file", content: small}
      ]

      %{results: compacted, total_saved: saved} =
        SnipCompact.snip_compact_tool_results(results)

      assert saved > 0
      [a, b, c, d] = compacted

      assert a.content =~ "[snipCompact:"
      assert b.content =~ "results found"
      # Exempt tools pass through untouched
      assert c.content == small
      assert d.content == small
    end

    test "preserves tool_use_id and ordering" do
      big = String.duplicate("x ", 2_000)

      results =
        for i <- 1..5 do
          %{tool_use_id: "id_#{i}", tool_name: "run_command", content: big}
        end

      %{results: out} = SnipCompact.snip_compact_tool_results(results)
      ids = Enum.map(out, & &1.tool_use_id)
      assert ids == ~w(id_1 id_2 id_3 id_4 id_5)
    end
  end
end
