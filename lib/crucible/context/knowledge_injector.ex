defmodule Crucible.Context.KnowledgeInjector do
  @moduledoc """
  Knowledge injection via synthetic tool_result messages.

  Port of `lib/api-executor/knowledge-injector.ts` from infra.

  Instead of bloating the system prompt with all context, inject plan notes,
  memory context, and phase handoffs as synthetic tool_result messages.
  The model attends more strongly to recent tool output than to system prompt
  text — this pattern keeps prompts lean and knowledge contextual.

  Public API:
    - `build_injections/1` — build synthetic message pairs from knowledge sources
    - `build_workflow_sources/1` — convenience builder for common workflow context
  """

  @type source_type :: :plan | :memory | :handoff | :lesson | :context

  @type knowledge_source :: %{
          type: source_type(),
          label: String.t(),
          content: String.t(),
          priority: number()
        }

  @type message :: %{role: String.t(), content: list(map())}

  @doc """
  Build synthetic tool_result message pairs for knowledge injection.

  Returns alternating assistant/user message pairs that simulate the model
  calling a `_context_loader` tool and receiving the knowledge as a result.
  Sorted by priority (highest first = injected earliest in conversation).
  """
  @spec build_injections([knowledge_source()]) :: [message()]
  def build_injections([]), do: []

  def build_injections(sources) when is_list(sources) do
    sources
    |> Enum.filter(fn s -> s.content != nil and String.trim(s.content) != "" end)
    |> Enum.sort_by(& &1.priority, :desc)
    |> Enum.flat_map(&source_to_messages/1)
  end

  @doc """
  Build injection sources from common workflow context.

  Priority ordering:
    - plan: 100 (highest — most relevant to task)
    - handoff: 80 (recent context from prior phases)
    - lesson: 60 (accumulated wisdom from memory vault)
    - memory: 40 (background project knowledge)
  """
  @spec build_workflow_sources(keyword()) :: [knowledge_source()]
  def build_workflow_sources(opts) when is_list(opts) do
    sources = []

    sources =
      cond do
        opts[:plan_note] && String.trim(opts[:plan_note]) != "" ->
          [
            %{type: :plan, label: "Implementation Plan", content: opts[:plan_note], priority: 100}
            | sources
          ]

        opts[:plan_summary] && String.trim(opts[:plan_summary]) != "" ->
          [
            %{type: :plan, label: "Plan Summary", content: opts[:plan_summary], priority: 100}
            | sources
          ]

        true ->
          sources
      end

    sources =
      case opts[:handoff_summaries] do
        summaries when is_list(summaries) and summaries != [] ->
          content = Enum.join(summaries, "\n\n---\n\n")

          [
            %{type: :handoff, label: "Prior Phase Results", content: content, priority: 80}
            | sources
          ]

        _ ->
          sources
      end

    sources =
      case opts[:lessons] do
        lessons when is_list(lessons) and lessons != [] ->
          content = Enum.join(lessons, "\n\n")
          [%{type: :lesson, label: "Relevant Lessons", content: content, priority: 60} | sources]

        _ ->
          sources
      end

    sources =
      case opts[:memory_context] do
        ctx when is_binary(ctx) and ctx != "" ->
          [%{type: :memory, label: "Project Context", content: ctx, priority: 40} | sources]

        _ ->
          sources
      end

    sources
  end

  # --- Private ---

  defp source_to_messages(source) do
    tool_use_id = "inject_#{source.type}_#{short_uuid()}"

    assistant_msg = %{
      role: "assistant",
      content: [
        %{
          "type" => "tool_use",
          "id" => tool_use_id,
          "name" => "_context_loader",
          "input" => %{"source" => to_string(source.type), "label" => source.label}
        }
      ]
    }

    user_msg = %{
      role: "user",
      content: [
        %{
          "type" => "tool_result",
          "tool_use_id" => tool_use_id,
          "content" => "[#{source.label}]\n\n#{source.content}"
        }
      ]
    }

    [assistant_msg, user_msg]
  end

  defp short_uuid do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end
end
