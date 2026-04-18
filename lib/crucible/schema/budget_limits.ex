defmodule Crucible.Schema.BudgetLimits do
  @moduledoc """
  Embedded Ecto schema for budget limits in the orchestration control plane.

  Defines spending thresholds that govern how much the system may spend at
  different granularity levels: per day, per agent, and per task. This schema
  is embedded within the budget system's parent forms and configuration structs
  — it is never persisted directly to a database table (`@primary_key false`).

  ## Fields

  | Field              | Type    | Default | Description                                  |
  |--------------------|---------|---------|----------------------------------------------|
  | `daily_limit_usd`  | `float` | `nil`   | Maximum USD spend allowed per calendar day   |
  | `agent_limit_usd`  | `float` | `nil`   | Maximum USD spend allowed per individual agent |
  | `task_limit_usd`   | `float` | `nil`   | Maximum USD spend allowed per single task    |

  ## Validation Rules (`changeset/2`)

  * **Required** — all three fields (`daily_limit_usd`, `agent_limit_usd`,
    `task_limit_usd`) must be present.
  * **Greater than zero** — each limit is validated with
    `validate_number/3` using `greater_than: 0`. Zero and negative values
    are rejected with the message `"must be > 0"`.

  ## Usage

  Typically embedded via `Ecto.Schema.embeds_one/3` in a parent schema or
  used standalone with `changeset/2` to validate budget-related form inputs
  before they are applied to the orchestration runtime (see env vars
  `DAILY_BUDGET_LIMIT_USD`, `AGENT_BUDGET_LIMIT_USD`, `TASK_BUDGET_LIMIT_USD`
  in `CLAUDE.md`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :daily_limit_usd, :float
    field :agent_limit_usd, :float
    field :task_limit_usd, :float
  end

  @fields ~w(daily_limit_usd agent_limit_usd task_limit_usd)a

  @type t :: %__MODULE__{
          daily_limit_usd: float() | nil,
          agent_limit_usd: float() | nil,
          task_limit_usd: float() | nil
        }

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(limits, attrs) do
    limits
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_number(:daily_limit_usd, greater_than: 0, message: "must be > 0")
    |> validate_number(:agent_limit_usd, greater_than: 0, message: "must be > 0")
    |> validate_number(:task_limit_usd, greater_than: 0, message: "must be > 0")
  end
end
