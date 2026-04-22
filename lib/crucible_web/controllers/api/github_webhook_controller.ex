defmodule CrucibleWeb.Api.GithubWebhookController do
  @moduledoc """
  Handles GitHub webhook events. Currently supports:
  - `pull_request` (closed+merged): moves the associated kanban card to "done"

  Only acts on PRs whose branch matches a workflow run (`run/` prefix).
  Validates the webhook signature via HMAC-SHA256 if GITHUB_WEBHOOK_SECRET is set.
  """
  use CrucibleWeb, :controller

  alias Crucible.Repo
  alias Crucible.Schema.Card
  alias Crucible.Kanban.DbAdapter
  import Ecto.Query
  require Logger

  # Branch prefix must be alphanumeric + dashes only, 8-16 chars
  @branch_prefix_pattern ~r/\A[a-zA-Z0-9\-]{8,16}\z/

  def receive(conn, params) do
    if valid_signature?(conn) do
      event = get_req_header(conn, "x-github-event") |> List.first()

      case handle_event(event, params) do
        :ok -> json(conn, %{status: "ok"})
        :ignored -> json(conn, %{status: "ignored"})
      end
    else
      conn |> put_status(401) |> json(%{error: "invalid signature"})
    end
  end

  defp handle_event("pull_request", %{"action" => "closed", "pull_request" => pr}) do
    if pr["merged"] do
      handle_pr_merged(pr)
    else
      Logger.debug("GithubWebhook: PR ##{pr["number"]} closed without merge — ignoring")
      :ignored
    end
  end

  defp handle_event(event, _params) do
    Logger.debug("GithubWebhook: ignoring event=#{inspect(event)}")
    :ignored
  end

  defp handle_pr_merged(pr) do
    branch = pr["head"]["ref"] || ""
    pr_number = pr["number"]

    if String.starts_with?(branch, "run/") do
      run_id_prefix = String.replace_prefix(branch, "run/", "")

      if Regex.match?(@branch_prefix_pattern, run_id_prefix) do
        move_card_for_run(run_id_prefix, pr_number)
      else
        Logger.warning("GithubWebhook: branch #{branch} has invalid run ID format — ignoring")
        :ignored
      end
    else
      Logger.debug(
        "GithubWebhook: PR ##{pr_number} branch #{branch} is not a run branch — ignoring"
      )

      :ignored
    end
  end

  defp move_card_for_run(run_id_prefix, pr_number) do
    card = find_card_by_run_branch(run_id_prefix)

    case card do
      nil ->
        Logger.debug("GithubWebhook: no card found for run prefix #{run_id_prefix} — ignoring")
        :ignored

      %Card{column: "done"} ->
        Logger.debug("GithubWebhook: card #{card.id} already done — ignoring")
        :ignored

      %Card{} = card ->
        {:ok, _} = DbAdapter.update_card(card.id, %{column: "done"})

        Logger.info(
          "GithubWebhook: PR ##{pr_number} merged — moved card #{card.id} (#{card.title}) to done"
        )

        :ok
    end
  end

  # Find a card whose run_id starts with the branch prefix.
  # Branch is "run/{runId[0:12]}", so we match cards whose run_id starts with that prefix.
  # Only matches non-archived, non-done cards.
  defp find_card_by_run_branch(run_id_prefix) do
    Repo.one(
      from c in Card,
        where: not c.archived,
        where: like(c.run_id, ^"#{run_id_prefix}%"),
        where: c.column != "done",
        order_by: [desc: c.updated_at],
        limit: 1
    )
  end

  # Verify GitHub webhook HMAC-SHA256 signature.
  # If GITHUB_WEBHOOK_SECRET is not configured, allow all requests (dev mode).
  defp valid_signature?(conn) do
    case System.get_env("GITHUB_WEBHOOK_SECRET") do
      nil -> true
      "" -> true
      secret -> verify_hmac(conn, secret)
    end
  end

  defp verify_hmac(conn, secret) do
    signature = get_req_header(conn, "x-hub-signature-256") |> List.first()

    case {signature, conn.assigns[:raw_body]} do
      {nil, _} ->
        Logger.warning("GithubWebhook: missing x-hub-signature-256 header")
        false

      {_, nil} ->
        # raw_body not captured — skip verification with warning
        Logger.warning("GithubWebhook: raw_body not available for signature verification")
        true

      {"sha256=" <> hex_digest, raw_body} ->
        expected = :crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower)
        Plug.Crypto.secure_compare(hex_digest, expected)

      _ ->
        false
    end
  end
end
