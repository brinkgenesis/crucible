defmodule Crucible.Context.KnowledgeInjectorTest do
  use ExUnit.Case, async: true

  alias Crucible.Context.KnowledgeInjector

  describe "build_injections/1" do
    test "returns empty list for empty sources" do
      assert KnowledgeInjector.build_injections([]) == []
    end

    test "creates assistant/user message pairs" do
      sources = [
        %{type: :plan, label: "Plan", content: "Build the thing", priority: 100}
      ]

      messages = KnowledgeInjector.build_injections(sources)
      assert length(messages) == 2

      [assistant, user] = messages
      assert assistant.role == "assistant"
      assert user.role == "user"

      [tool_use] = assistant.content
      assert tool_use["type"] == "tool_use"
      assert tool_use["name"] == "_context_loader"
      assert tool_use["input"]["source"] == "plan"

      [tool_result] = user.content
      assert tool_result["type"] == "tool_result"
      assert tool_result["content"] =~ "[Plan]"
      assert tool_result["content"] =~ "Build the thing"
    end

    test "sorts by priority descending" do
      sources = [
        %{type: :memory, label: "Memory", content: "bg context", priority: 40},
        %{type: :plan, label: "Plan", content: "do stuff", priority: 100},
        %{type: :lesson, label: "Lessons", content: "learned things", priority: 60}
      ]

      messages = KnowledgeInjector.build_injections(sources)
      assert length(messages) == 6

      # First pair should be plan (priority 100)
      [first_assistant | _] = messages
      [tool_use] = first_assistant.content
      assert tool_use["input"]["source"] == "plan"
    end

    test "skips sources with empty content" do
      sources = [
        %{type: :plan, label: "Plan", content: "real content", priority: 100},
        %{type: :memory, label: "Memory", content: "", priority: 40},
        %{type: :lesson, label: "Lesson", content: "   ", priority: 60}
      ]

      messages = KnowledgeInjector.build_injections(sources)
      assert length(messages) == 2
    end

    test "tool_use_id links assistant and user messages" do
      sources = [
        %{type: :handoff, label: "Handoff", content: "phase 1 done", priority: 80}
      ]

      [assistant, user] = KnowledgeInjector.build_injections(sources)
      [tool_use] = assistant.content
      [tool_result] = user.content

      assert tool_use["id"] == tool_result["tool_use_id"]
      assert tool_use["id"] =~ "inject_handoff_"
    end
  end

  describe "build_workflow_sources/1" do
    test "builds sources from plan_note" do
      sources = KnowledgeInjector.build_workflow_sources(plan_note: "Build auth module")
      assert length(sources) == 1
      [source] = sources
      assert source.type == :plan
      assert source.priority == 100
      assert source.content == "Build auth module"
    end

    test "prefers plan_note over plan_summary" do
      sources =
        KnowledgeInjector.build_workflow_sources(
          plan_note: "full plan",
          plan_summary: "summary"
        )

      assert length(sources) == 1
      [source] = sources
      assert source.content == "full plan"
    end

    test "falls back to plan_summary when no plan_note" do
      sources = KnowledgeInjector.build_workflow_sources(plan_summary: "short summary")
      [source] = sources
      assert source.label == "Plan Summary"
    end

    test "builds all source types" do
      sources =
        KnowledgeInjector.build_workflow_sources(
          plan_note: "the plan",
          handoff_summaries: ["phase 1 done", "phase 2 done"],
          lessons: ["always test", "check types"],
          memory_context: "project uses Hono"
        )

      assert length(sources) == 4
      types = Enum.map(sources, & &1.type) |> Enum.sort()
      assert types == [:handoff, :lesson, :memory, :plan]
    end

    test "skips empty/nil values" do
      sources =
        KnowledgeInjector.build_workflow_sources(
          plan_note: nil,
          handoff_summaries: [],
          lessons: nil,
          memory_context: ""
        )

      assert sources == []
    end
  end
end
