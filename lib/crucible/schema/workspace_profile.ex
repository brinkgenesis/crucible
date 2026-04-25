defmodule Crucible.Schema.WorkspaceProfile do
  @moduledoc """
  Ecto schema for workspace profiles, backed by the `workspaces` table.

  A workspace profile represents a configured project workspace within the
  orchestrator. Each workspace maps to a repository and carries execution
  policy settings that govern workflow runs:

  ## Fields

    * `name` — human-readable workspace name
    * `slug` — unique URL-safe identifier (lowercase alphanumeric, hyphens, underscores)
    * `repo_path` — absolute path to the repository on disk
    * `tech_context` — freeform description injected into LLM plan prompts
    * `default_workflow` — workflow template used when none is specified (default: `"coding-sprint"`)
    * `allowed_models` — list of model IDs permitted for this workspace
    * `cost_limit_usd` — per-run spending cap in USD (must be >= 0)
    * `approval_threshold` — complexity score (1–10) above which human approval is required

  ## Associations

    * `has_many :cards` — kanban cards scoped to this workspace

  ## Changesets

    * `changeset/2` — full creation/update; validates required fields, slug format, and policy constraints
    * `policy_changeset/2` — partial update for policy fields only (`allowed_models`, `cost_limit_usd`, `approval_threshold`)
  """
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [inserted_at: :created_at]
  @primary_key {:id, :string, autogenerate: false}

  schema "workspaces" do
    field :name, :string
    field :slug, :string
    field :repo_path, :string
    field :tech_context, :string, default: ""
    field :default_branch, :string, default: "main"
    field :default_workflow, :string, default: "coding-sprint"
    field :allowed_models, {:array, :string}, default: []
    field :cost_limit_usd, :decimal
    field :approval_threshold, :integer
    field :last_run_started_at, :utc_datetime

    has_many :cards, Crucible.Schema.Card, foreign_key: :workspace_id

    timestamps(type: :utc_datetime)
  end

  @required ~w(name slug repo_path)a
  @optional ~w(tech_context default_branch default_workflow allowed_models cost_limit_usd approval_threshold)a

  @type t :: %__MODULE__{}

  @policy_fields ~w(allowed_models cost_limit_usd approval_threshold)a

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(ws, attrs) do
    ws
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_format(:slug, ~r/^[a-z0-9_-]+$/,
      message: "must be lowercase alphanumeric with hyphens/underscores"
    )
    |> unique_constraint(:slug)
    |> validate_policy_fields()
  end

  @doc "Changeset for policy-only updates (no name/slug/repo_path required)."
  @spec policy_changeset(t(), map()) :: Ecto.Changeset.t()
  def policy_changeset(ws, attrs) do
    ws
    |> cast(attrs, @policy_fields)
    |> validate_policy_fields()
  end

  defp validate_policy_fields(changeset) do
    changeset
    |> validate_number(:cost_limit_usd, greater_than_or_equal_to: 0, message: "must be >= 0")
    |> validate_number(:approval_threshold,
      greater_than: 0,
      less_than_or_equal_to: 10,
      message: "must be between 1 and 10"
    )
  end
end
