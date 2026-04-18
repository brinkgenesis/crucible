defmodule Crucible.ElixirSdk.ToolRegistry do
  @moduledoc """
  Registry of available tools.

  Default registry maps Anthropic's standard tool names
  (Read, Write, Edit, Bash, Glob, Grep, Task) to Crucible-native
  implementations. Consumers can override via
  `Application.put_env(:crucible, :elixir_sdk_tools, %{...})`.
  """

  alias Crucible.ElixirSdk.Tools

  @default %{
    "Read" => Tools.Read,
    "Write" => Tools.Write,
    "Edit" => Tools.Edit,
    "Bash" => Tools.Bash,
    "Glob" => Tools.Glob,
    "Grep" => Tools.Grep,
    "Task" => Tools.Task,
    "WebFetch" => Tools.WebFetch,
    "WebSearch" => Tools.WebSearch,
    "NotebookEdit" => Tools.NotebookEdit
  }

  @doc "Returns the full tool registry (built-ins + live MCP tools) as [{name, module}]."
  @spec all() :: [{String.t(), module() | map()}]
  def all do
    builtins = registry() |> Enum.into([])
    builtins ++ mcp_tools()
  end

  @doc "Returns only the requested tool names, in order."
  @spec pick([String.t()]) :: [{String.t(), module() | map()}]
  def pick(names) do
    reg = registry()
    mcp = Enum.into(mcp_tools(), %{})

    names
    |> Enum.map(fn name ->
      cond do
        mod = Map.get(reg, name) -> {name, mod}
        entry = Map.get(mcp, name) -> {name, entry}
        true -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc "Look up a tool module by name. Prefixed `mcp__...` names route through McpTool."
  @spec lookup(String.t()) :: {:ok, module()} | :error
  def lookup("mcp__" <> _ = _name) do
    {:ok, Crucible.ElixirSdk.Tools.McpTool}
  end

  def lookup(name) do
    case Map.fetch(registry(), name) do
      {:ok, mod} -> {:ok, mod}
      :error -> :error
    end
  end

  # Live-fetched MCP tool list. Each entry is `{name, schema_map}` so the
  # caller (Query) can render the schema directly; lookup/1 handles the
  # dispatch back to the MCP client.
  defp mcp_tools do
    try do
      Crucible.ElixirSdk.Mcp.Client.registered_tools()
    catch
      _kind, _err -> []
    end
  end

  defp registry do
    Application.get_env(:crucible, :elixir_sdk_tools, @default)
  end
end
