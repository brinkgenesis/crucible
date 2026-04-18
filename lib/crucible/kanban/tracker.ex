defmodule Crucible.Kanban.Tracker do
  @moduledoc """
  Behaviour for kanban card tracking.
  Implementations: DbAdapter (Ecto-backed), MemoryAdapter (in-memory for tests).
  """

  @type column :: String.t()

  @type card :: %{
          id: String.t(),
          title: String.t(),
          column: column(),
          version: non_neg_integer(),
          archived: boolean(),
          metadata: map()
        }

  @callback list_cards(filters :: keyword()) :: {:ok, [card()]}
  @callback get_card(id :: String.t()) :: {:ok, card()} | {:error, :not_found}
  @callback create_card(attrs :: map()) :: {:ok, card()} | {:error, term()}
  @callback move_card(id :: String.t(), column :: column(), version :: non_neg_integer()) ::
              {:ok, card()} | {:error, term()}
  @callback move_card(id :: String.t(), column :: column()) ::
              {:ok, card()} | {:error, term()}
  @callback update_card(id :: String.t(), attrs :: map(), version :: non_neg_integer()) ::
              {:ok, card()} | {:error, term()}
  @callback update_card(id :: String.t(), attrs :: map()) ::
              {:ok, card()} | {:error, term()}
  @callback archive_card(id :: String.t()) :: {:ok, card()} | {:error, term()}
  @callback restore_card(id :: String.t()) :: {:ok, card()} | {:error, term()}
  @callback delete_card(id :: String.t()) :: :ok | {:error, term()}
  @callback card_history(id :: String.t(), opts :: keyword()) :: {:ok, [map()]}
  @callback log_card_event(id :: String.t(), event_type :: String.t(), payload :: map()) ::
              {:ok, map()} | {:error, term()}
end
