defmodule Crucible.MemoryHealthReader do
  @moduledoc """
  Stub for memory vault health stats.

  The memory vault feature is out of scope for the v0 Crucible release. This
  module returns empty/zero values so the health endpoint keeps rendering.
  Replace or delete when vault support ships.
  """
  @spec health_stats() :: map()
  def health_stats, do: %{}
end

defmodule Crucible.SavingsReader do
  @moduledoc """
  Stub for router cost-savings analytics.

  Savings reporting is derived from trace events in the running system; this
  stub returns empty maps so the LiveView dashboards keep loading before the
  real reader is wired to the new schema.
  """
  @spec build_stats() :: map()
  def build_stats, do: %{total_saved_usd: 0.0, by_model: %{}, sample_size: 0}

  @spec build_global_savings() :: map()
  def build_global_savings, do: %{total_saved_usd: 0.0, total_runs: 0, window_hours: 0}

  @spec cache_entries() :: non_neg_integer()
  def cache_entries, do: 0
end

defmodule Crucible.Actionability do
  @moduledoc """
  Stub for the "turn this trace event into a kanban card" quick-action.

  Real implementation depends on inbox ingestion which is out of scope.
  Callers get a standard not-implemented tuple so the UI can show a graceful
  error instead of crashing.
  """
  @spec create_action_card(map()) :: {:ok, map()} | {:error, atom()}
  def create_action_card(_params), do: {:error, :not_implemented}
end

defmodule Crucible.VaultPlanStore do
  @moduledoc """
  Stub for Obsidian-backed plan note lookup.

  Plan generation is now in-band (LLM-generated via the dashboard API), so
  vault reads return not-found rather than loading a note from disk.
  """
  @spec read_note(String.t()) :: {:ok, map()} | {:error, atom()}
  def read_note(_path), do: {:error, :not_found}

  @spec store_plan(String.t(), String.t(), String.t()) :: {:ok, atom()} | {:error, atom()}
  def store_plan(_card_id, _title, _body), do: {:ok, :noop}

  @spec list_notes() :: [map()]
  def list_notes, do: []
end

defmodule Crucible.PatrolScanner do
  @moduledoc """
  Stub for inbox patrol scanning.

  Inbox ingestion is out of scope for Crucible. This exists only so legacy
  callers in the kanban LiveView keep compiling; it returns ok without doing
  anything.
  """
  @spec schedule_scan(keyword()) :: {:ok, atom()} | {:error, term()}
  def schedule_scan(_opts), do: {:ok, :noop}
end

defmodule Crucible.LearnTool do
  @moduledoc """
  Stub for vault lesson promotion.

  Self-improvement still emits KPIs and hints, but vault-backed lesson
  promotion is a Phase-3 feature. This stub lets the self-improvement loop
  finish each cycle without calling into the missing vault module.
  """
  @spec promote_learnings(String.t(), keyword()) :: :ok | {:error, term()}
  def promote_learnings(_run_id, _opts), do: :ok
end

defmodule Crucible.TaskTool do
  @moduledoc """
  Stub for the scheduled-job task tool.

  Scheduled personal jobs were removed from Crucible. This stub keeps the
  agent_job_manager alias resolvable.
  """
  @spec noop() :: :ok
  def noop, do: :ok

  @spec spawn_child(any(), any(), any()) :: {:ok, map()} | {:error, atom()}
  def spawn_child(_parent_run, _parent_phase, _task_config), do: {:error, :not_supported}
end

defmodule Crucible.BenchmarkAutopilot do
  @moduledoc """
  Stub for the benchmark autopilot hook.

  Benchmark publication was removed from the Crucible core. The self-improvement
  loop calls this after each completed run; we return :ok to keep the pipeline
  wired without doing work.
  """
  @spec process_completed_run(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def process_completed_run(_run_id, _opts), do: {:ok, :noop}

  @spec sweep(keyword()) :: {:ok, list()} | {:error, term()}
  def sweep(_opts), do: {:ok, []}
end

defmodule Crucible.HarborEvalIngestor do
  @moduledoc """
  Stub — research benchmark ingestion is out of scope for v0.
  """
  @spec sweep(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep(_opts), do: {:ok, 0}
end

defmodule Crucible.AttentionBudget do
  @moduledoc """
  Stub for the per-agent attention budget tracker.

  Token-flow visualisation is a deferred feature; callers get empty data
  so the related dashboard pages render cleanly.
  """
  @spec summary() :: map()
  def summary, do: %{agents: [], tasks: []}

  @spec agent_status(String.t()) :: map() | nil
  def agent_status(_agent_id), do: nil
end

defmodule Crucible.Flywheels do
  @moduledoc """
  Stub for the token-flow flywheel computation.

  Replaces the heavier upstream module that derived recommendations from
  router cost data. Returns empty state so callers degrade gracefully.
  """
  @spec compute() :: map()
  def compute, do: %{}

  @spec compute(String.t()) :: map()
  def compute(_infra_home), do: %{}

  @spec recommendations(map()) :: list()
  def recommendations(_state), do: []
end

defmodule Crucible.TeamReader do
  @moduledoc """
  Stub for ~/.claude/teams config inspection.

  The teams page lives on without a backing reader for v0; users can still
  inspect runs and traces, just not browse historical team configs.
  """
  @spec get_team(String.t()) :: map() | nil
  def get_team(_name), do: nil

  @spec export_markdown(String.t()) :: String.t() | nil | {:error, atom()}
  def export_markdown(_name), do: {:error, :not_supported}
end

defmodule Crucible.ClientContext do
  @moduledoc """
  Stub — multi-client repo metadata is deferred to a later release.
  """
  @spec build(any(), any()) :: map() | nil
  def build(_repo, _client_id), do: nil
end
