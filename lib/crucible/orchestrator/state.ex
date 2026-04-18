defmodule Crucible.Orchestrator.State do
  @moduledoc """
  Orchestrator state struct.

  Per-run state lives in `Orchestrator.RunServer` — the Orchestrator only
  tracks workflow-level concerns: circuit breakers, completed set, and config.
  """

  @type circuit_state :: %{
          state: :closed | :open | :half_open,
          consecutive_failures: non_neg_integer(),
          opened_at: integer() | nil,
          cooldown_ms: pos_integer(),
          last_failed_at: integer() | nil
        }

  @type t :: %__MODULE__{
          poll_interval_ms: pos_integer(),
          max_concurrent_runs: pos_integer(),
          runs_dir: String.t(),
          completed: %{String.t() => integer()},
          circuit_breakers: %{String.t() => circuit_state()},
          budget_halted: boolean(),
          config: keyword()
        }

  defstruct [
    :poll_interval_ms,
    :max_concurrent_runs,
    :runs_dir,
    completed: %{},
    circuit_breakers: %{},
    budget_halted: false,
    config: []
  ]

  @doc "Creates a new state from validated config."
  @spec new(keyword()) :: t()
  def new(config) do
    repo_root = Keyword.get(config, :repo_root, File.cwd!())
    runs_dir = Path.join(repo_root, Keyword.get(config, :runs_dir, ".claude-flow/runs"))

    %__MODULE__{
      poll_interval_ms: Keyword.get(config, :poll_interval_ms, 2_000),
      max_concurrent_runs: Keyword.get(config, :max_concurrent_runs, 5),
      runs_dir: runs_dir,
      config: config
    }
  end
end
