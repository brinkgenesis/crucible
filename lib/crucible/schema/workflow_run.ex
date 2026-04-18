defmodule Crucible.Schema.WorkflowRun do
  @moduledoc "Workflow execution manifest. Maps to `workflow_runs` table."
  use Ecto.Schema
  import Ecto.Changeset

  alias Crucible.Schema.{PhaseEntry, PolicyConfig, PullRequest}

  @timestamps_opts [inserted_at: :created_at]
  @primary_key {:run_id, :string, autogenerate: false}

  schema "workflow_runs" do
    field :card_id, :string
    field :workflow_name, :string
    field :workspace_path, :string
    field :task_description, :string
    field :version, :integer, default: 0
    field :status, :string, default: "pending"
    field :execution_type, :string, default: "subscription"
    embeds_many :phases, PhaseEntry, on_replace: :delete
    field :plan_note, :string
    field :plan_summary, :string
    field :complexity, :integer
    field :base_commit, :string
    field :session_resume_chain, {:array, :string}
    field :last_transition_key, :string
    field :retry_count, :integer, default: 0
    field :max_retries, :integer
    field :current_phase_index, :integer
    field :current_phase_status, :string
    field :active_node, :string
    field :trigger_source, :string
    field :primary_model, :string

    embeds_one :policy, PolicyConfig, on_replace: :update
    embeds_one :pull_request, PullRequest, on_replace: :update

    field :client_id, :string

    timestamps(type: :utc_datetime)
  end

  @required ~w(workflow_name task_description)a
  @optional ~w(card_id version status execution_type plan_note plan_summary
               complexity base_commit session_resume_chain last_transition_key
               retry_count max_retries client_id workspace_path
               current_phase_index current_phase_status active_node
               trigger_source primary_model)a

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, @required ++ @optional)
    |> cast_embed(:phases, with: &PhaseEntry.changeset/2)
    |> cast_embed(:policy, with: &PolicyConfig.changeset/2)
    |> cast_embed(:pull_request, with: &PullRequest.changeset/2)
    |> validate_required(@required)
    |> validate_inclusion(:status, ~w(pending running completed failed cancelled))
    |> validate_inclusion(:execution_type, ~w(subscription api))
  end
end
