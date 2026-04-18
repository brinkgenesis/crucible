defmodule Crucible.Schema.Card do
  @moduledoc "Kanban card. Maps to `cards` table."
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [inserted_at: :created_at]
  @primary_key {:id, :string, autogenerate: false}

  @columns ~w(ideation unassigned todo in_progress review done)

  schema "cards" do
    field :title, :string
    field :column, :string
    field :version, :integer, default: 0
    field :archived, :boolean, default: false
    field :archived_at, :utc_datetime
    field :workflow, :string
    field :run_id, :string
    field :estimated_cost_usd, :decimal
    field :agent_role, :string
    field :phase_name, :string
    field :spawned_at, :utc_datetime
    field :pid, :integer
    field :parent_card_id, :string
    field :phase_cards, {:array, :map}
    field :phase_depends_on, {:array, :string}
    field :metadata, :map

    field :client_id, :string
    belongs_to :workspace, Crucible.Schema.WorkspaceProfile, type: :string
    has_many :events, Crucible.Schema.CardEvent, foreign_key: :card_id
    has_many :children, __MODULE__, foreign_key: :parent_card_id

    timestamps(type: :utc_datetime)
  end

  @required ~w(title column)a
  @optional ~w(version archived archived_at workflow run_id estimated_cost_usd
               agent_role phase_name spawned_at pid parent_card_id
               phase_cards phase_depends_on metadata client_id workspace_id)a

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(card, attrs) do
    card
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:title, min: 1, max: 500)
    |> validate_inclusion(:column, @columns)
  end
end
