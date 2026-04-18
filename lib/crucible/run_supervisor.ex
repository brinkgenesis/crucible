defmodule Crucible.RunSupervisor do
  @moduledoc """
  Deprecated: delegates to `Crucible.Orchestrator.RunSupervisor`.

  Kept for backward compatibility with modules that alias the old name.
  """

  alias Crucible.Orchestrator.RunSupervisor, as: Canonical

  defdelegate start_link(opts \\ []), to: Canonical
  defdelegate start_run(run_opts), to: Canonical
  defdelegate terminate_run(pid), to: Canonical
  defdelegate active_count(), to: Canonical
end
