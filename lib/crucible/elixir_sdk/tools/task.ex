defmodule Crucible.ElixirSdk.Tools.Task do
  @moduledoc """
  Spawn a subagent — a nested `Crucible.ElixirSdk.Query` with its own
  prompt, tools, and conversation history.

  If `subagent_type` matches a registered `Crucible.ElixirSdk.AgentDef`,
  the definition's tools/model/system-prompt/permission-mode are applied.
  Otherwise the subagent inherits the parent's context.
  """

  @behaviour Crucible.ElixirSdk.Tool

  alias Crucible.ElixirSdk.{AgentDef, Query}

  @default_subagent_model "claude-sonnet-4-6"
  @subagent_timeout_ms 300_000
  @subagent_max_turns 10

  @impl true
  def schema do
    %{
      name: "Task",
      description: """
      Delegate a focused sub-task to a subagent. Pass `subagent_type` to
      use a custom agent definition (loaded from the workflow YAML) —
      otherwise the subagent inherits the caller's tools and model.
      """,
      input_schema: %{
        type: "object",
        required: ["description", "prompt"],
        properties: %{
          description: %{type: "string", description: "3-5 word title."},
          prompt: %{type: "string", description: "Full subagent instructions."},
          subagent_type: %{type: "string", description: "Optional registered agent name."}
        }
      }
    }
  end

  @impl true
  def run(%{"prompt" => prompt} = input, ctx) do
    description = Map.get(input, "description", "subagent")
    agent_type = Map.get(input, "subagent_type")
    agent_def = AgentDef.lookup(agent_type)

    model =
      Map.get(input, "model") ||
        (agent_def && agent_def.model) ||
        @default_subagent_model

    opts =
      [
        prompt: prompt,
        model: model,
        cwd: ctx.cwd,
        permission_mode:
          (agent_def && agent_def.permission_mode) ||
            ctx.permission_mode,
        max_turns: (agent_def && agent_def.max_turns) || @subagent_max_turns,
        timeout_ms: @subagent_timeout_ms,
        subscriber: self()
      ]
      |> maybe_put_opt(:agent_type, agent_type)
      |> maybe_put_opt(:system, agent_def && agent_def.system_prompt)
      |> maybe_put_opt(:tools, agent_def && agent_def.tools)

    with {:ok, pid} <- Query.start_link(opts),
         {:ok, result} <- Query.await(pid, @subagent_timeout_ms) do
      header =
        "--- subagent: #{description} (#{result.turns} turns, #{result.tool_calls} tool calls) ---\n"

      {:ok, header <> (result.text || "")}
    else
      {:error, reason} -> {:error, "subagent failed: #{inspect(reason)}"}
    end
  end

  def run(_, _), do: {:error, "Task requires `description` and `prompt`."}

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
