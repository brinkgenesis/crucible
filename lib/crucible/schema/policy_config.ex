defmodule Crucible.Schema.PolicyConfig do
  @moduledoc """
  Embedded schema for workflow run policy configuration.

  Stores the routing policy applied to a workflow run, including which policy
  variant (active or candidate) was selected and whether the run is part of a
  canary evaluation. Embedded in `WorkflowRun` via `embeds_one :policy`.

  ## Fields

    * `policy_id` — identifier of the routing policy used for this run
    * `variant` — either `"active"` (production) or `"candidate"` (experimental)
    * `canary` — whether this run is a canary evaluation against the candidate variant
    * `timings` — arbitrary timing metadata (e.g. phase durations, latency budgets)
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :policy_id, :string
    field :variant, :string
    field :canary, :boolean, default: false
    field :timings, :map
  end

  @fields ~w(policy_id variant canary timings)a

  @type t :: %__MODULE__{
          policy_id: String.t() | nil,
          variant: String.t() | nil,
          canary: boolean(),
          timings: map() | nil
        }

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(config, attrs) do
    config
    |> cast(attrs, @fields)
    |> validate_inclusion(:variant, ~w(active candidate))
  end
end
