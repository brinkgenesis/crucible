defmodule Crucible.Config do
  @moduledoc """
  Runtime configuration with NimbleOptions validation.
  Mirrors Symphony's Config module.
  """

  @schema NimbleOptions.new!(
            poll_interval_ms: [
              type: :pos_integer,
              default: 2_000,
              doc: "Orchestrator poll interval in milliseconds."
            ],
            max_concurrent_runs: [
              type: :pos_integer,
              default: 5,
              doc: "Maximum concurrent workflow runs."
            ],
            daily_budget_usd: [
              type: :float,
              default: 100.0,
              doc: "Daily budget limit in USD."
            ],
            agent_budget_usd: [
              type: :float,
              default: 10.0,
              doc: "Per-agent budget limit in USD."
            ],
            task_budget_usd: [
              type: :float,
              default: 50.0,
              doc: "Per-task budget limit in USD."
            ],
            runs_dir: [
              type: :string,
              default: ".claude-flow/runs",
              doc: "Directory for run manifests."
            ],
            workflows_dir: [
              type: :string,
              default: "workflows",
              doc: "Directory for workflow YAML files."
            ],
            cost_events_path: [
              type: :string,
              default: "cost-events.jsonl",
              doc: "Path to cost events JSONL file."
            ],
            claude_executable: [
              type: :string,
              default: "claude",
              doc: "Path to Claude CLI executable."
            ],
            self_improvement_interval_ms: [
              type: :pos_integer,
              default: 1_800_000,
              doc: "Self-improvement check interval (default 30 min)."
            ],
            repo_root: [
              type: :string,
              doc: "Repository root path."
            ]
          )

  @doc "Validates and returns configuration from application env."
  @spec load!() :: keyword()
  def load! do
    opts =
      Application.get_all_env(:crucible)
      |> Keyword.get(:orchestrator, [])
      |> Keyword.put_new(:repo_root, File.cwd!())

    NimbleOptions.validate!(opts, @schema)
  end

  @doc "Returns the NimbleOptions schema for documentation."
  def schema, do: @schema
end
