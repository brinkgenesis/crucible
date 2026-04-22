defmodule Crucible.Jobs.StaleCardArchiver do
  @moduledoc """
  Archives cards that have accumulated 3+ failed workflow runs.
  Prevents stale todo cards from continuously spawning failing runs.

  Runs every 6 hours via Oban cron. Creates audit events for each archived card.
  """

  use Oban.Worker,
    queue: :patrol,
    max_attempts: 2,
    unique: [period: 6 * 3600]

  require Logger

  import Ecto.Query

  alias Crucible.Repo
  alias Crucible.Schema.{Card, CardEvent, WorkflowRun}

  @failure_threshold 3

  @impl Oban.Worker
  def perform(_job) do
    stale_cards =
      from(c in Card,
        join: r in WorkflowRun,
        on: r.card_id == c.id,
        where: c.archived == false and r.status == "failed",
        group_by: [c.id, c.title],
        having: count(r.run_id) >= @failure_threshold,
        select: {c.id, c.title, count(r.run_id)}
      )
      |> Repo.all()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    archived_count =
      Enum.count(stale_cards, fn {card_id, title, fail_count} ->
        case archive_card(card_id, title, fail_count, now) do
          :ok -> true
          :error -> false
        end
      end)

    if archived_count > 0 do
      Logger.info(
        "StaleCardArchiver: archived #{archived_count} cards with #{@failure_threshold}+ failures"
      )
    end

    :ok
  end

  defp archive_card(card_id, title, fail_count, now) do
    case Repo.get(Card, card_id) do
      nil ->
        :error

      card ->
        Repo.transaction(fn ->
          changeset =
            card
            |> Ecto.Changeset.change(%{archived: true, archived_at: now, column: "done"})

          case Repo.update(changeset) do
            {:ok, _} -> :ok
            {:error, cs} -> Repo.rollback({:update_failed, cs})
          end

          event_cs =
            %CardEvent{}
            |> CardEvent.changeset(%{
              card_id: card_id,
              event_type: "card.archived",
              actor: "system",
              payload: %{"reason" => "stale_failures", "failure_count" => fail_count},
              occurred_at: now
            })

          case Repo.insert(event_cs) do
            {:ok, _} -> :ok
            {:error, cs} -> Repo.rollback({:insert_failed, cs})
          end
        end)
        |> case do
          {:ok, _} ->
            Logger.info("StaleCardArchiver: archived '#{title}' (#{fail_count} failures)")
            :ok

          {:error, reason} ->
            Logger.warning(
              "StaleCardArchiver: failed to archive card #{card_id}: #{inspect(reason)}"
            )

            :error
        end
    end
  end
end
