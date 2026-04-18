defmodule Crucible.Schema.PhaseEntry do
  @moduledoc "Embedded schema for a single workflow phase stored in WorkflowRun.phases JSONB."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :id, :string
    field :name, :string
    field :type, :string, default: "session"
    field :status, :string, default: "pending"
    field :phase_index, :integer, default: 0
    field :session_id, :string
    field :retry_count, :integer, default: 0
    field :timeout_ms, :integer, default: 600_000
    field :depends_on, {:array, :string}, default: []
    # JSONB stores agents as either ["role"] (legacy) or [%{"role" => "..."}] (current).
    # Use {:array, :any} to accept both without crashing on schema load.
    field :agents, {:array, :any}, default: []
    field :create_branch, :boolean, default: false
  end

  @fields ~w(id name type status phase_index session_id retry_count timeout_ms depends_on agents create_branch)a

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @fields)
  end
end
