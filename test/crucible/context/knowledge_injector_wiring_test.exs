defmodule Crucible.Context.KnowledgeInjectorWiringTest do
  @moduledoc """
  Tests that KnowledgeInjector integrates correctly with the adapter
  and query message building pipeline.
  """
  use ExUnit.Case, async: true

  alias Crucible.Context.KnowledgeInjector

  describe "adapter → query integration contract" do
    test "build_workflow_sources from run-like data produces valid injections" do
      # Simulate what the ElixirSdk adapter builds from a workflow run
      sources =
        KnowledgeInjector.build_workflow_sources(
          plan_note: "## Plan\n1. Build auth module\n2. Add tests\n3. Deploy",
          lessons: ["Always validate JWT expiry", "Use adapter pattern for integrations"]
        )

      assert length(sources) == 2

      messages = KnowledgeInjector.build_injections(sources)

      # 2 sources × 2 messages each = 4 messages
      assert length(messages) == 4

      # Plan should come first (priority 100 > 60)
      [first_assistant, first_user | _] = messages
      [tool_use] = first_assistant.content
      assert tool_use["input"]["source"] == "plan"

      [tool_result] = first_user.content
      assert tool_result["content"] =~ "Build auth module"

      # Then lessons
      [_, _, lesson_assistant, lesson_user] = messages
      [lesson_tool_use] = lesson_assistant.content
      assert lesson_tool_use["input"]["source"] == "lesson"

      [lesson_result] = lesson_user.content
      assert lesson_result["content"] =~ "JWT expiry"
    end

    test "empty run context produces no injections" do
      sources =
        KnowledgeInjector.build_workflow_sources(
          plan_note: nil,
          plan_summary: nil,
          lessons: nil
        )

      assert sources == []
      assert KnowledgeInjector.build_injections(sources) == []
    end

    test "injections merged with user prompt maintain alternating roles" do
      sources =
        KnowledgeInjector.build_workflow_sources(plan_note: "Do the thing")

      injections = KnowledgeInjector.build_injections(sources)

      # The prompt must be merged into the last user message to avoid
      # consecutive user-role messages (which the Anthropic API rejects).
      # This validates the contract that query.ex's merge_knowledge_and_prompt
      # depends on: injections end on a user-role message.
      assert length(injections) == 2
      [_assistant, last_user] = injections
      assert last_user.role == "user"

      # Simulating what merge_knowledge_and_prompt does:
      merged_content = last_user.content ++ [%{"type" => "text", "text" => "Now execute"}]
      merged = %{last_user | content: merged_content}
      all_messages = [hd(injections), merged]

      roles = Enum.map(all_messages, & &1.role)
      assert roles == ["assistant", "user"]
    end

    test "message format matches Anthropic API requirements" do
      sources = [
        %{type: :handoff, label: "Phase 1 Results", content: "Schema created", priority: 80}
      ]

      [assistant_msg, user_msg] = KnowledgeInjector.build_injections(sources)

      # Assistant message has tool_use block
      [tool_use] = assistant_msg.content
      assert is_binary(tool_use["id"])
      assert tool_use["type"] == "tool_use"
      assert tool_use["name"] == "_context_loader"
      assert is_map(tool_use["input"])

      # User message has matching tool_result block
      [tool_result] = user_msg.content
      assert tool_result["type"] == "tool_result"
      assert tool_result["tool_use_id"] == tool_use["id"]
      assert is_binary(tool_result["content"])
    end
  end
end
