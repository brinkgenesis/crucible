defmodule Crucible.Sandbox.Provider do
  @moduledoc """
  Behaviour for sandbox providers.

  Implementations manage container lifecycle for isolated tool execution.
  Two implementations: `LocalProvider` (no-op passthrough for dev) and
  `DockerProvider` (real Docker-based isolation for production).
  """

  @type sandbox_id :: String.t()

  @type sandbox_opts :: %{
          workspace_path: String.t(),
          policy: Crucible.Sandbox.Policy.t(),
          image: String.t(),
          labels: map()
        }

  @callback start_sandbox(sandbox_opts) :: {:ok, sandbox_id} | {:error, term()}
  @callback stop_sandbox(sandbox_id) :: :ok | {:error, term()}
  @callback exec(sandbox_id, command :: String.t(), keyword()) ::
              {:ok, String.t()} | {:error, term()}
  @callback status(sandbox_id) :: :running | :stopped | :unknown
end
