defmodule Crucible.CiLog.CardSurfacer do
  @moduledoc """
  CI Card Surfacer — creates or updates kanban cards for CI review results.

  Port of `lib/ci/card-surfacer.ts` from infra.

  Deduplicates by title: if an open card with the same `[CI]` title exists
  from the ci-log-analyzer source, it updates the recurrence count instead of
  creating a duplicate. Skips severity === "info".

  Public API:
    - `surface/2` — surface a review analysis as a kanban card
  """

  require Logger

  alias Crucible.Kanban.DbAdapter
  alias Crucible.Repo
  alias Crucible.Schema.Card

  import Ecto.Query

  @source "ci-log-analyzer"

  @type context :: %{run_id: String.t(), workflow_name: String.t()}

  @doc """
  Surface a CI review result as a kanban card.

  Skips `"info"` severity. Deduplicates by matching title among non-archived cards.
  For recurring issues, increments the `occurrences` count in card metadata.

  Returns `{:ok, card_id}` or `{:ok, nil}` if skipped.
  """
  @spec surface(map(), context()) :: {:ok, String.t() | nil} | {:error, term()}
  def surface(analysis, context) when is_map(analysis) and is_map(context) do
    if analysis.severity == "info" do
      {:ok, nil}
    else
      title = "[CI] #{analysis.category}: #{analysis.title}"

      metadata = %{
        "source" => @source,
        "run_id" => context.run_id,
        "workflow_name" => context.workflow_name,
        "category" => analysis.category,
        "severity" => analysis.severity,
        "suggested_fix" => analysis.suggested_fix
      }

      case find_open_card(title) do
        nil ->
          create_new_card(title, Map.put(metadata, "occurrences", 1))

        existing when analysis.is_recurring ->
          update_recurring(existing, metadata)

        existing ->
          Logger.info("Skipping non-recurring duplicate CI card: #{title}")
          {:ok, existing.id}
      end
    end
  end

  # --- Private ---

  defp find_open_card(title) do
    Card
    |> where([c], c.archived == false)
    |> where([c], c.title == ^title)
    |> where([c], fragment("?->>'source' = ?", c.metadata, @source))
    |> limit(1)
    |> Repo.one()
  end

  defp create_new_card(title, metadata) do
    case DbAdapter.create_card(%{title: title, column: "unassigned", metadata: metadata}) do
      {:ok, card} ->
        Logger.info("Created CI card: #{card.id} — #{title}")
        {:ok, card.id}

      {:error, reason} ->
        Logger.warning("CI card creation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp update_recurring(existing, metadata) do
    current_occurrences = get_in(existing.metadata || %{}, ["occurrences"]) || 1
    updated_metadata = Map.put(metadata, "occurrences", current_occurrences + 1)

    case DbAdapter.update_card(existing.id, %{metadata: updated_metadata}, existing.version) do
      {:ok, card} ->
        Logger.info("Updated recurring CI card: #{card.id}")
        {:ok, card.id}

      {:error, reason} ->
        Logger.warning("CI card update failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
