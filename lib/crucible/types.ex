defmodule Crucible.Types do
  @moduledoc """
  Core type definitions for the orchestrator.
  Maps to lib/cli/workflow/types.ts from the TypeScript codebase.
  """

  defmodule Run do
    @moduledoc "A workflow run manifest."
    @type status ::
            :pending
            | :running
            | :review
            | :done
            | :completed
            | :failed
            | :cancelled
            | :orphaned
            | :budget_paused

    @type policy :: %{
            policy_id: String.t() | nil,
            variant: String.t() | nil,
            canary: boolean(),
            timings: map() | nil
          }

    @type pull_request :: %{
            branch_name: String.t() | nil,
            number: non_neg_integer() | nil,
            url: String.t() | nil
          }

    @type t :: %__MODULE__{
            id: String.t(),
            workflow_type: String.t(),
            status: status(),
            phases: [Phase.t()],
            workspace_path: String.t() | nil,
            branch: String.t() | nil,
            plan_note: String.t() | nil,
            plan_summary: String.t() | nil,
            budget_usd: float(),
            client_id: String.t() | nil,
            session_resume_chain: %{optional(non_neg_integer()) => String.t()} | nil,
            started_at: DateTime.t() | nil,
            completed_at: DateTime.t() | nil,
            error: String.t() | nil,
            card_id: String.t() | nil,
            task_description: String.t() | nil,
            version: non_neg_integer(),
            complexity: non_neg_integer() | nil,
            base_commit: String.t() | nil,
            execution_type: String.t(),
            last_transition_key: String.t() | nil,
            retry_count: non_neg_integer(),
            max_retries: non_neg_integer(),
            policy: policy() | nil,
            on_complete_create_card: map() | nil,
            paused_at_phase_index: non_neg_integer() | nil,
            pull_request: pull_request() | nil
          }

    defstruct [
      :id,
      :workflow_type,
      :workspace_path,
      :branch,
      :plan_note,
      :plan_summary,
      :client_id,
      :session_resume_chain,
      :started_at,
      :completed_at,
      :error,
      :card_id,
      :task_description,
      :complexity,
      :base_commit,
      :last_transition_key,
      :policy,
      :on_complete_create_card,
      :paused_at_phase_index,
      :pull_request,
      status: :pending,
      phases: [],
      budget_usd: 50.0,
      phase_budget_usd: nil,
      version: 0,
      execution_type: "subscription",
      retry_count: 0,
      max_retries: 3,
      task_depth: 0
    ]
  end

  defmodule Phase do
    @moduledoc "A single phase within a workflow run."
    @type phase_type ::
            :session | :team | :api | :review_gate | :pr_shepherd | :preflight

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            type: phase_type(),
            status: Run.status(),
            prompt: String.t() | nil,
            work_units: [WorkUnit.t()],
            agents: [map()],
            depends_on: [String.t()],
            max_retries: non_neg_integer(),
            retry_count: non_neg_integer(),
            timeout_ms: pos_integer(),
            phase_index: non_neg_integer(),
            session_id: String.t() | nil,
            token_metrics: PhaseTokenMetrics.t() | nil,
            parallel: boolean(),
            estimated_cost_usd: float() | nil,
            routing_profile: String.t() | nil,
            create_branch: boolean(),
            plan_approval_agents: [String.t()]
          }

    defstruct [
      :id,
      :name,
      :prompt,
      :session_id,
      :token_metrics,
      :estimated_cost_usd,
      :routing_profile,
      type: :session,
      status: :pending,
      work_units: [],
      agents: [],
      depends_on: [],
      max_retries: 2,
      retry_count: 0,
      timeout_ms: 600_000,
      phase_index: 0,
      parallel: false,
      create_branch: false,
      plan_approval_agents: []
    ]
  end

  defmodule PhaseTokenMetrics do
    @moduledoc "Token efficiency metrics collected during phase execution."

    @type t :: %__MODULE__{
            session_resumed: boolean(),
            retry_count: non_neg_integer(),
            duration_ms: non_neg_integer(),
            exit_code: integer() | nil,
            budget_usd: float() | nil,
            input_tokens: non_neg_integer(),
            output_tokens: non_neg_integer(),
            cache_read_tokens: non_neg_integer(),
            result: String.t() | nil
          }

    defstruct session_resumed: false,
              retry_count: 0,
              duration_ms: 0,
              exit_code: nil,
              budget_usd: nil,
              input_tokens: 0,
              output_tokens: 0,
              cache_read_tokens: 0,
              result: nil
  end

  defmodule WorkUnit do
    @moduledoc "A unit of work (file or task) assigned to a phase."
    @type t :: %__MODULE__{
            id: String.t() | nil,
            path: String.t(),
            files: [String.t()],
            read_files: [String.t()],
            description: String.t() | nil,
            role: String.t() | nil,
            context_boundary: [String.t()],
            depends_on: [String.t()],
            acceptance_criteria: [String.t()]
          }

    defstruct [
      :id,
      :path,
      :description,
      :role,
      files: [],
      read_files: [],
      context_boundary: [],
      depends_on: [],
      acceptance_criteria: []
    ]
  end

  defmodule AgentUpdate do
    @moduledoc "A streaming update from a running agent."
    @type update_type :: :progress | :token_usage | :phase_complete | :error

    @type t :: %__MODULE__{
            run_id: String.t(),
            phase_id: String.t() | nil,
            type: update_type(),
            data: map()
          }

    defstruct [:run_id, :phase_id, :type, data: %{}]
  end
end
