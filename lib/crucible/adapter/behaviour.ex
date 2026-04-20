defmodule Crucible.Adapter.Behaviour do
  @moduledoc """
  Behaviour for execution adapters.
  Implementations: ClaudePort (tmux), ClaudeSdk (Node SDK port bridge),
  ElixirSdk (native Elixir), ClaudeHook (file-trigger).
  """

  alias Crucible.Types.{Run, Phase}

  @doc "Execute a phase within a run context."
  @callback execute_phase(
              run :: Run.t(),
              phase :: Phase.t(),
              prompt :: String.t(),
              opts :: keyword()
            ) ::
              {:ok, map()} | {:error, term()}

  @doc "Clean up any artifacts from a phase execution."
  @callback cleanup_artifacts(run :: Run.t(), phase :: Phase.t()) :: :ok
end
