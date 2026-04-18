defmodule Crucible.Schema.ConversationHistory do
  @moduledoc "Stores conversation turns for context window management."
  use Ecto.Schema

  schema "conversation_history" do
    field :run_id, :string
    field :phase_index, :integer
    field :turn_number, :integer
    field :role, :string
    field :content, :string
    field :token_count, :integer, default: 0
    field :is_summary, :boolean, default: false

    timestamps(type: :utc_datetime)
  end
end
