defmodule Crucible.Schema.PullRequest do
  @moduledoc """
  Embedded schema tracking pull requests created by workflow runs.

  Stores the branch name, PR number, and URL for pull requests opened during
  automated workflow execution. Embedded within `Crucible.Schema.WorkflowRun`
  to link a run to the PR it produced, and referenced from
  `Crucible.Schema.Card` when a card's workflow generates a PR.

  ## Fields

    * `:branch_name` — the git branch associated with the pull request
    * `:number` — the pull request number on the remote (e.g. GitHub)
    * `:url` — full URL to the pull request
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :branch_name, :string
    field :number, :integer
    field :url, :string
  end

  @fields ~w(branch_name number url)a

  @type t :: %__MODULE__{
          branch_name: String.t() | nil,
          number: non_neg_integer() | nil,
          url: String.t() | nil
        }

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(pr, attrs) do
    pr
    |> cast(attrs, @fields)
  end
end
