defmodule Crucible.Workspace.Backend do
  @moduledoc """
  Behaviour for workspace backend abstraction (P5).

  Decouples API workflow tools from storage, enabling:
  - Local filesystem (default)
  - Docker containers (future)
  - Remote sandboxes via SSH/NATS (future)

  MCP is already our tool layer; this adds workspace isolation beneath it.
  """

  @type path :: String.t()
  @type opts :: keyword()
  @type content :: binary()

  @doc "Read a file from the workspace."
  @callback read(path(), opts()) :: {:ok, content()} | {:error, term()}

  @doc "Write content to a file in the workspace."
  @callback write(path(), content(), opts()) :: :ok | {:error, term()}

  @doc "Execute a command in the workspace."
  @callback exec(String.t(), opts()) :: {:ok, String.t()} | {:error, term()}

  @doc "List files at a path in the workspace."
  @callback list(path(), opts()) :: {:ok, [String.t()]} | {:error, term()}

  @doc "Check if a path exists in the workspace."
  @callback exists?(path(), opts()) :: boolean()

  @doc "Delete a file from the workspace."
  @callback delete(path(), opts()) :: :ok | {:error, term()}

  @doc "Create a directory in the workspace."
  @callback mkdir_p(path(), opts()) :: :ok | {:error, term()}
end
