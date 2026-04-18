defmodule Crucible.ElixirSdk.Tools.McpTool do
  @moduledoc """
  Thin adapter that forwards a tool call to the MCP client.

  MCP tools aren't known at compile time — they're discovered at runtime
  from each configured MCP server. The `ToolRegistry` includes a function
  that appends the live MCP tools to the built-in registry; Query passes
  each tool's schema to Anthropic so the model can call it by name.

  When the model emits `{tool: "mcp__weather__get_forecast", input: %{...}}`,
  `ToolRegistry.lookup/1` resolves that prefixed name to this module,
  which hands the call off to `Crucible.ElixirSdk.Mcp.Client.call_tool/2`.
  """

  @behaviour Crucible.ElixirSdk.Tool

  # Non-MCP tools use their own schema. This module is used only for
  # dispatch; the Query renders each MCP tool's schema directly from the
  # registry list. `schema/0` is therefore a placeholder.
  @impl true
  def schema do
    %{
      name: "McpTool",
      description: "Forward to an MCP server tool.",
      input_schema: %{type: "object"}
    }
  end

  @impl true
  def run(input, ctx) do
    case Map.get(ctx, :mcp_tool_name) do
      nil -> {:error, "McpTool requires mcp_tool_name in ctx"}
      name -> Crucible.ElixirSdk.Mcp.Client.call_tool(name, input)
    end
  end
end
