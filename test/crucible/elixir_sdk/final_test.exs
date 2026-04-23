defmodule Crucible.ElixirSdk.FinalTest do
  @moduledoc """
  Unit tests for the final batch of SDK features: approval logic,
  MCP name parsing / registry integration, compactor split logic,
  and the NotebookEdit tool.
  """
  use ExUnit.Case, async: true

  alias Crucible.ElixirSdk.{Approval, Compactor, Tools}

  # ── Approval ──────────────────────────────────────────────────────────

  describe "Approval.decide/4" do
    test "read-only tools always allowed" do
      ctx = %{cwd: ".", permission_mode: :ask}

      for tool <- ~w(Read Grep Glob Task WebFetch WebSearch) do
        assert Approval.decide(tool, %{}, ctx) == :allow
      end
    end

    test "bypass_permissions lets routine mutations through" do
      ctx = %{cwd: ".", permission_mode: :bypass_permissions}
      # bypass allows edits and safe bash
      assert Approval.decide("Bash", %{"command" => "ls"}, ctx) == :allow
      assert Approval.decide("Edit", %{}, ctx) == :allow
      # …but the command classifier still blocks critical bash regardless
      assert {:deny, _} = Approval.decide("Bash", %{"command" => "rm -rf /"}, ctx)
    end

    test "accept_edits allows Write/Edit/NotebookEdit but still asks for Bash" do
      ctx = %{cwd: ".", permission_mode: :accept_edits}
      assert Approval.decide("Edit", %{}, ctx) == :allow
      assert Approval.decide("Write", %{}, ctx) == :allow
      assert Approval.decide("NotebookEdit", %{}, ctx) == :allow
      # Bash falls through to ask mode and default callback denies
      assert {:deny, _} = Approval.decide("Bash", %{}, ctx)
    end

    test "plan mode blocks all mutations" do
      ctx = %{cwd: ".", permission_mode: :plan}
      assert {:deny, reason} = Approval.decide("Write", %{}, ctx)
      assert reason =~ "plan mode"
    end

    test "ask mode uses the supplied callback" do
      cb = fn "Bash", %{"command" => "ls"}, _ctx -> :allow end
      ctx = %{cwd: ".", permission_mode: :ask}

      assert Approval.decide("Bash", %{"command" => "ls"}, ctx, on_approval: cb) == :allow
    end

    test "ask mode denies when callback returns deny" do
      cb = fn _tool, _input, _ctx -> {:deny, "nope"} end
      ctx = %{cwd: ".", permission_mode: :ask}

      assert {:deny, "nope"} = Approval.decide("Edit", %{}, ctx, on_approval: cb)
    end

    test "ask mode denies when callback crashes" do
      cb = fn _tool, _input, _ctx -> raise "boom" end
      ctx = %{cwd: ".", permission_mode: :ask}

      assert {:deny, reason} = Approval.decide("Write", %{}, ctx, on_approval: cb)
      assert reason =~ "crashed"
    end
  end

  # ── Compactor ──────────────────────────────────────────────────────────

  describe "Compactor.maybe_compact/3" do
    test "skips when below threshold" do
      messages = Enum.map(1..3, fn i -> %{role: "user", content: "msg #{i}"} end)
      assert {:skip, :below_threshold} = Compactor.maybe_compact(messages, 40.0, [])
    end

    test "skips when too few turns even above threshold" do
      messages = Enum.map(1..4, fn i -> %{role: "user", content: "msg #{i}"} end)
      assert {:skip, :too_few_turns} = Compactor.maybe_compact(messages, 90.0, [])
    end

    # The summariser path requires a real API key; skipped in unit tests.
  end

  describe "Compactor.split_for_compaction/2" do
    test "keeps knowledge-injection (tool_use/tool_result) pair in prefix with the prompt" do
      # Simulates: one knowledge_injection source + prompt merged into last user
      # message, plus three completed (assistant tool_use, user tool_result) turns.
      inject_assistant = %{
        role: "assistant",
        content: [%{"type" => "tool_use", "id" => "inject_plan_abc", "name" => "_context_loader"}]
      }

      inject_user_with_prompt = %{
        role: "user",
        content: [
          %{"type" => "tool_result", "tool_use_id" => "inject_plan_abc", "content" => "[plan]\n..."},
          %{"type" => "text", "text" => "the real prompt"}
        ]
      }

      turn = fn id ->
        [
          %{role: "assistant", content: [%{"type" => "tool_use", "id" => id, "name" => "Read"}]},
          %{role: "user", content: [%{"type" => "tool_result", "tool_use_id" => id, "content" => "ok"}]}
        ]
      end

      messages =
        [inject_assistant, inject_user_with_prompt] ++
          turn.("t1") ++ turn.("t2") ++ turn.("t3")

      {prefix, middle, suffix} = Compactor.split_for_compaction(messages, 4)

      # Prefix keeps the knowledge_injection pair AND the prompt together.
      assert length(prefix) == 2
      assert List.last(prefix).role == "user"

      # Suffix must open on an assistant turn so tool_use/tool_result stays paired.
      assert hd(suffix).role == "assistant"

      # Middle contains exactly the collapsible interior turns.
      assert Enum.all?(middle, &is_map/1)
      assert length(prefix) + length(middle) + length(suffix) == length(messages)
    end

    test "falls back to first-message prefix when no prompt text is present" do
      messages = [
        %{role: "user", content: [%{"type" => "tool_result", "tool_use_id" => "x", "content" => "ok"}]},
        %{role: "assistant", content: [%{"type" => "tool_use", "id" => "a", "name" => "Read"}]},
        %{role: "user", content: [%{"type" => "tool_result", "tool_use_id" => "a", "content" => "ok"}]}
      ]

      {prefix, _middle, _suffix} = Compactor.split_for_compaction(messages, 2)

      # No text block anywhere — falls back to the old "keep the first message" behaviour.
      assert length(prefix) == 1
    end

    test "realigns suffix to start on an assistant message" do
      # Build enough turns that middle gets non-empty content.
      prompt_msg = %{role: "user", content: [%{"type" => "text", "text" => "prompt"}]}

      turn = fn id ->
        [
          %{role: "assistant", content: [%{"type" => "tool_use", "id" => id, "name" => "Read"}]},
          %{role: "user", content: [%{"type" => "tool_result", "tool_use_id" => id, "content" => "ok"}]}
        ]
      end

      messages = [prompt_msg] ++ turn.("t1") ++ turn.("t2") ++ turn.("t3")

      # keep_recent = 3 would naively place a user message at the suffix head,
      # orphaning its assistant tool_use in middle. Realignment must fix that.
      {_prefix, _middle, suffix} = Compactor.split_for_compaction(messages, 3)

      assert hd(suffix).role == "assistant"
    end
  end

  # ── ToolRegistry MCP prefix routing ────────────────────────────────────

  describe "ToolRegistry with MCP prefix" do
    test "lookup routes mcp__ names to McpTool" do
      assert {:ok, Crucible.ElixirSdk.Tools.McpTool} =
               Crucible.ElixirSdk.ToolRegistry.lookup("mcp__weather__get_forecast")
    end

    test "lookup still returns built-in tools for normal names" do
      assert {:ok, Crucible.ElixirSdk.Tools.Read} =
               Crucible.ElixirSdk.ToolRegistry.lookup("Read")
    end

    test "lookup returns :error for unknown tool" do
      assert :error = Crucible.ElixirSdk.ToolRegistry.lookup("NotRegistered")
    end
  end

  # ── NotebookEdit ───────────────────────────────────────────────────────

  describe "NotebookEdit" do
    setup do
      tmp =
        Path.join([System.tmp_dir!(), "crucible-nbe-#{System.unique_integer([:positive])}"])

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      notebook = %{
        "cells" => [
          %{
            "cell_type" => "code",
            "source" => ["print('hello')\n"],
            "metadata" => %{},
            "outputs" => [],
            "execution_count" => nil
          },
          %{"cell_type" => "markdown", "source" => ["# Heading\n"], "metadata" => %{}}
        ],
        "metadata" => %{},
        "nbformat" => 4,
        "nbformat_minor" => 5
      }

      path = Path.join(tmp, "sample.ipynb")
      File.write!(path, Jason.encode!(notebook))

      {:ok, tmp: tmp, path: path, ctx: %{cwd: tmp, permission_mode: :default}}
    end

    test "replace swaps cell source", %{path: path, ctx: ctx} do
      assert {:ok, _} =
               Tools.NotebookEdit.run(
                 %{
                   "notebook_path" => "sample.ipynb",
                   "cell_number" => 0,
                   "new_source" => "x = 1\ny = 2"
                 },
                 ctx
               )

      nb = File.read!(path) |> Jason.decode!()
      cell = Enum.at(nb["cells"], 0)
      assert cell["source"] |> Enum.join() =~ "x = 1"
      assert cell["outputs"] == []
    end

    test "insert adds a markdown cell", %{path: path, ctx: ctx} do
      assert {:ok, _} =
               Tools.NotebookEdit.run(
                 %{
                   "notebook_path" => "sample.ipynb",
                   "cell_number" => 1,
                   "new_source" => "## Inserted",
                   "cell_type" => "markdown",
                   "edit_mode" => "insert"
                 },
                 ctx
               )

      nb = File.read!(path) |> Jason.decode!()
      assert length(nb["cells"]) == 3
      assert Enum.at(nb["cells"], 1)["cell_type"] == "markdown"
    end

    test "delete removes a cell", %{path: path, ctx: ctx} do
      assert {:ok, _} =
               Tools.NotebookEdit.run(
                 %{
                   "notebook_path" => "sample.ipynb",
                   "cell_number" => 1,
                   "edit_mode" => "delete"
                 },
                 ctx
               )

      nb = File.read!(path) |> Jason.decode!()
      assert length(nb["cells"]) == 1
    end

    test "plan mode does not write", %{path: path, tmp: tmp} do
      ctx = %{cwd: tmp, permission_mode: :plan}
      original = File.read!(path)

      assert {:ok, msg} =
               Tools.NotebookEdit.run(
                 %{
                   "notebook_path" => "sample.ipynb",
                   "cell_number" => 0,
                   "new_source" => "different"
                 },
                 ctx
               )

      assert msg =~ "plan mode"
      assert File.read!(path) == original
    end
  end
end
