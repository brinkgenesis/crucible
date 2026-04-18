defmodule Crucible.Schema.TraceEvent do
  @moduledoc "Execution trace/telemetry event. Maps to `trace_events` table."
  use Ecto.Schema
  import Ecto.Changeset

  schema "trace_events" do
    field :timestamp, :utc_datetime
    field :trace_id, :string
    field :run_id, :string
    field :phase_id, :string
    field :agent_id, :string
    field :session_id, :string
    field :event_type, :string
    field :tool, :string
    field :detail, :string
    field :metadata, :map, default: %{}

    field :client_id, :string
  end

  @required ~w(timestamp trace_id event_type)a
  @optional ~w(run_id phase_id agent_id session_id tool detail metadata client_id)a

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
  end
end
