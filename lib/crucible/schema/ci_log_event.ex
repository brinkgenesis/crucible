defmodule Crucible.Schema.CiLogEvent do
  @moduledoc "CI log event from a failed GitHub Actions run. Maps to `ci_log_events` table."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @conclusions ~w(failure cancelled timed_out action_required)

  schema "ci_log_events" do
    field(:run_id, :string)
    field(:workflow_name, :string)
    field(:conclusion, :string)
    field(:duration_ms, :integer, default: 0)
    field(:failure_summary, :string, default: "")
    field(:raw_log, :string, default: "")
    field(:analyzed_at, :utc_datetime)
    field(:analysis, :map)
    field(:created_at, :utc_datetime)

    timestamps()
  end

  @required ~w(run_id workflow_name conclusion)a
  @optional ~w(duration_ms failure_summary raw_log analyzed_at analysis created_at)a

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:conclusion, @conclusions)
    |> unique_constraint(:run_id)
  end
end
