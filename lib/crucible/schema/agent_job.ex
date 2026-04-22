defmodule Crucible.Schema.AgentJob do
  @moduledoc "Async agent job. Postgres-backed (not in-memory like DeepAgents)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "agent_jobs" do
    field :run_id, :string
    field :parent_phase, :string
    field :config, :map, default: %{}
    field :status, :string, default: "pending"
    field :result, :map
    field :error, :string
    field :launched_at, :utc_datetime
    field :completed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @valid_statuses ~w(pending running completed failed cancelled)

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :run_id,
      :parent_phase,
      :config,
      :status,
      :result,
      :error,
      :launched_at,
      :completed_at
    ])
    |> validate_inclusion(:status, @valid_statuses)
  end

  @type t :: %__MODULE__{}
end
