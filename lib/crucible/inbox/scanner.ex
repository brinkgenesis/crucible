defmodule Crucible.Inbox.Scanner do
  @moduledoc """
  Inbox scan pipeline — load unread items, evaluate, surface cards.

  Port of `lib/inbox/scan-pipeline.ts` from infra (generic subset).

  Pipeline: load unread → evaluate each → assign buckets → create cards
  for auto-promotes → update item statuses.

  Public API:
    - `scan/0` — run a full scan with default router
    - `scan/1` — run with options (router_fn, max_items, thresholds)
  """

  require Logger

  import Ecto.Query

  alias Crucible.Inbox.EvalFilter
  alias Crucible.Kanban.DbAdapter
  alias Crucible.Repo
  alias Crucible.Schema.InboxItem

  @max_items 200
  @max_auto_promotes 10

  @type scan_result :: %{
          total_items: non_neg_integer(),
          evaluated: non_neg_integer(),
          cards_created: non_neg_integer(),
          dismissed: non_neg_integer(),
          for_review: non_neg_integer(),
          errors: non_neg_integer()
        }

  @doc "Run a full inbox scan with default settings."
  @spec scan(keyword()) :: {:ok, scan_result()}
  def scan(opts \\ []) do
    max_items = Keyword.get(opts, :max_items, @max_items)
    router_fn = Keyword.get(opts, :router_fn)

    items = load_unread(max_items)

    if items == [] do
      Logger.debug("InboxScanner: no unread items")
      {:ok, empty_result()}
    else
      Logger.info("InboxScanner: scanning #{length(items)} unread items")
      result = process_items(items, router_fn)

      :telemetry.execute(
        [:crucible, :inbox, :scan_complete],
        %{
          total: result.total_items,
          evaluated: result.evaluated,
          cards_created: result.cards_created,
          dismissed: result.dismissed,
          for_review: result.for_review,
          errors: result.errors
        },
        %{}
      )

      {:ok, result}
    end
  end

  @doc "Load unread inbox items up to a limit."
  @spec load_unread(non_neg_integer()) :: [InboxItem.t()]
  def load_unread(limit \\ @max_items) do
    InboxItem
    |> where([i], i.status == "unread")
    |> order_by([i], asc: i.ingested_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # --- Private ---

  defp process_items(items, router_fn) do
    result = empty_result() |> Map.put(:total_items, length(items))

    Enum.reduce(items, result, fn item, acc ->
      eval_args =
        if router_fn, do: [item_to_eval_map(item), router_fn], else: [item_to_eval_map(item)]

      case apply(EvalFilter, :evaluate, eval_args) do
        {:ok, eval} ->
          acc = %{acc | evaluated: acc.evaluated + 1}
          store_eval_result(item, eval)
          apply_bucket(item, eval, acc)

        {:error, _reason} ->
          %{acc | errors: acc.errors + 1}
      end
    end)
  end

  defp item_to_eval_map(item) do
    %{
      id: item.id,
      title: item.title,
      original_text: item.original_text,
      summary: item.summary
    }
  end

  defp store_eval_result(item, eval) do
    eval_map = %{
      "dimensions" =>
        Enum.map(eval.dimensions, fn d ->
          %{"criterion" => d.criterion, "score" => d.score, "note" => d.note}
        end),
      "labels" => eval.labels,
      "average_score" => eval.average_score,
      "feedback" => eval.feedback,
      "bucket" => eval.bucket
    }

    case item |> InboxItem.changeset(%{eval_result: eval_map}) |> Repo.update() do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("InboxScanner: failed to store eval for #{item.id}: #{inspect(reason)}")
    end
  end

  defp apply_bucket(item, eval, acc) do
    case eval.bucket do
      "auto-promote" ->
        if acc.cards_created < @max_auto_promotes do
          case create_card_for_item(item, eval) do
            {:ok, card_id} ->
              update_item_status(item, "actioned", card_id)
              %{acc | cards_created: acc.cards_created + 1}

            {:error, _} ->
              %{acc | errors: acc.errors + 1}
          end
        else
          update_item_status(item, "read")
          %{acc | for_review: acc.for_review + 1}
        end

      "review" ->
        update_item_status(item, "read")
        %{acc | for_review: acc.for_review + 1}

      "low-priority" ->
        update_item_status(item, "read")
        %{acc | for_review: acc.for_review + 1}

      "dismiss" ->
        update_item_status(item, "dismissed")
        %{acc | dismissed: acc.dismissed + 1}
    end
  end

  defp create_card_for_item(item, eval) do
    title = "[Inbox] #{item.title || "Untitled item"}"

    metadata = %{
      "source" => "inbox-scanner",
      "inbox_item_id" => item.id,
      "eval_score" => eval.average_score,
      "eval_bucket" => eval.bucket,
      "labels" => eval.labels
    }

    DbAdapter.create_card(%{title: title, column: "unassigned", metadata: metadata})
    |> case do
      {:ok, card} ->
        Logger.info("InboxScanner: created card #{card.id} for item #{item.id}")
        {:ok, card.id}

      {:error, reason} ->
        Logger.warning("InboxScanner: card creation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp update_item_status(item, status, card_id \\ nil) do
    attrs = %{status: status}
    attrs = if card_id, do: Map.put(attrs, :card_id, card_id), else: attrs

    item
    |> InboxItem.changeset(attrs)
    |> Repo.update()
  end

  defp empty_result do
    %{
      total_items: 0,
      evaluated: 0,
      cards_created: 0,
      dismissed: 0,
      for_review: 0,
      errors: 0
    }
  end
end
