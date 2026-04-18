defmodule Crucible.ElixirSdk.AdvancedTest do
  @moduledoc """
  Unit tests for the Elixir SDK's advanced features.

  We exercise the synchronous helpers (course corrector, agent def loader,
  context usage estimator) directly — they don't require an API call.
  Live streaming tests still rely on real credentials and are skipped here.
  """
  use ExUnit.Case, async: true

  alias Crucible.ElixirSdk.{AgentDef, ContextUsage, CourseCorrector}

  # ── CourseCorrector ────────────────────────────────────────────────────

  describe "CourseCorrector" do
    test "no-op on empty history" do
      assert :ok = CourseCorrector.analyse([])
    end

    test "detects repeated bash loops" do
      calls = for _ <- 1..4, do: %{name: "Bash", input: %{"command" => "ls"}}
      assert {:correct, msg} = CourseCorrector.analyse(calls)
      assert msg =~ "same bash command"
    end

    test "detects identical Edit re-applies" do
      call = %{
        name: "Edit",
        input: %{
          "file_path" => "a.ex",
          "old_string" => "x",
          "new_string" => "y"
        }
      }

      assert {:correct, msg} = CourseCorrector.analyse([call, call])
      assert msg =~ "Edit call"
    end

    test "detects generic tool-input repetition" do
      call = %{name: "Read", input: %{"file_path" => "x.ex"}}
      calls = for _ <- 1..3, do: call
      assert {:correct, msg} = CourseCorrector.analyse(calls)
      assert msg =~ "same tool"
    end

    test "mixed tool calls don't trigger" do
      calls = [
        %{name: "Read", input: %{"file_path" => "a.ex"}},
        %{name: "Edit", input: %{"file_path" => "a.ex", "old_string" => "x", "new_string" => "y"}},
        %{name: "Bash", input: %{"command" => "mix compile"}}
      ]

      assert :ok = CourseCorrector.analyse(calls)
    end
  end

  # ── AgentDef ────────────────────────────────────────────────────────────

  describe "AgentDef" do
    setup do
      AgentDef.clear()
      :ok
    end

    test "register + lookup round-trip" do
      AgentDef.register(%AgentDef{name: "reviewer", model: "claude-opus-4-6", tools: ["Read", "Grep"]})
      def = AgentDef.lookup("reviewer")
      assert def.model == "claude-opus-4-6"
      assert def.tools == ["Read", "Grep"]
    end

    test "load_from_yaml accepts string or atom keys" do
      AgentDef.load_from_yaml([
        %{"name" => "coder", "model" => "claude-sonnet-4-6", "tools" => ["Read", "Write", "Edit", "Bash"]},
        %{name: "researcher", model: "claude-haiku-4-5-20251001", tools: ["Read", "Grep", "Glob"]}
      ])

      assert AgentDef.lookup("coder").model == "claude-sonnet-4-6"
      assert AgentDef.lookup("researcher").tools == ["Read", "Grep", "Glob"]
    end

    test "lookup/nil returns nil" do
      assert AgentDef.lookup(nil) == nil
      assert AgentDef.lookup("not-registered") == nil
    end

    test "permission_mode string is normalised to atom" do
      AgentDef.load_from_yaml([%{"name" => "planner", "permission_mode" => "plan"}])
      assert AgentDef.lookup("planner").permission_mode == :plan
    end
  end

  # ── ContextUsage ────────────────────────────────────────────────────────

  describe "ContextUsage" do
    test "returns 0% for empty usage" do
      snap = ContextUsage.snapshot(%{input: 0, output: 0}, "claude-sonnet-4-6")
      assert snap.percentage == 0.0
      assert snap.max_tokens == 200_000
    end

    test "accumulates input + output against window" do
      snap = ContextUsage.snapshot(%{input: 100_000, output: 50_000}, "claude-sonnet-4-6")
      assert snap.total_tokens == 150_000
      assert snap.percentage == 75.0
    end

    test "unknown model defaults to 200k window" do
      snap = ContextUsage.snapshot(%{input: 200_000, output: 0}, "unknown-model")
      assert snap.percentage == 100.0
    end
  end
end
