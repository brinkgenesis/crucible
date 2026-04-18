defmodule Crucible.ElixirSdk.Mcp.Connection do
  @moduledoc """
  Behaviour for an MCP server connection.

  Implementations: `Crucible.ElixirSdk.Mcp.Stdio` (subprocess) and
  `Crucible.ElixirSdk.Mcp.Http` (remote server). Both speak JSON-RPC 2.0
  and expose the same synchronous `call/3` for the client manager.
  """

  @callback start_link(config :: map()) :: GenServer.on_start()
  @callback call(server :: GenServer.server(), method :: String.t(), params :: map()) ::
              {:ok, term()} | {:error, term()}
  @callback close(server :: GenServer.server()) :: :ok
end
