defmodule CrucibleWeb.Api.InboxIngestController do
  @moduledoc """
  HTTP ingress for the inbox pipeline.

  Two actions:

    * `:link` — authenticated JSON POST that files a URL into the inbox
      (source: `"link"`). Routed through the session-authed `/api/v1`
      scope, so only logged-in dashboard users can call it.

    * `:webhook` — unauthenticated JSON POST for external systems. Verifies
      an HMAC-SHA256 signature against the raw body when
      `INBOX_WEBHOOK_SECRET` is set. Scope: `/api/v1/webhooks/inbox`.
  """

  use CrucibleWeb, :controller

  alias Crucible.Inbox.Ingesters.{Link, Webhook}

  require Logger

  @signature_header "x-crucible-signature-256"

  # --- :link (authenticated user flow) ---

  def link(conn, %{"url" => url} = params) when is_binary(url) do
    opts =
      []
      |> maybe_put(:title, params["title"])
      |> maybe_put(:note, params["note"])
      |> maybe_put(:author, author_from_conn(conn, params))

    case Link.ingest(url, opts) do
      {:ok, status, item} ->
        conn
        |> put_status(if status == :inserted, do: 201, else: 200)
        |> json(%{status: Atom.to_string(status), id: item.id, url: item.source_id})

      {:error, :invalid_url} ->
        conn |> put_status(400) |> json(%{error: "invalid_url"})

      {:error, %Ecto.Changeset{} = cs} ->
        conn |> put_status(422) |> json(%{error: "validation_failed", details: errors(cs)})
    end
  end

  def link(conn, _params) do
    conn |> put_status(400) |> json(%{error: "url_required"})
  end

  # --- :webhook (external HMAC-verified flow) ---

  def webhook(conn, params) do
    with :ok <- verify_signature(conn) do
      case Webhook.ingest(params) do
        {:ok, status} ->
          json(conn, %{status: Atom.to_string(status)})

        {:error, :missing_source_id} ->
          conn |> put_status(400) |> json(%{error: "missing_source_id"})

        {:error, %Ecto.Changeset{} = cs} ->
          conn |> put_status(422) |> json(%{error: "validation_failed", details: errors(cs)})
      end
    else
      {:error, reason} ->
        Logger.warning("InboxIngest: webhook rejected — #{reason}")
        conn |> put_status(401) |> json(%{error: "unauthorized"})
    end
  end

  # --- Private ---

  defp maybe_put(opts, _k, nil), do: opts
  defp maybe_put(opts, _k, ""), do: opts
  defp maybe_put(opts, k, v), do: Keyword.put(opts, k, v)

  defp author_from_conn(conn, params) do
    cond do
      is_binary(params["author"]) and params["author"] != "" -> params["author"]
      user = conn.assigns[:current_user] -> Map.get(user, :email) || Map.get(user, "email")
      true -> nil
    end
  end

  defp verify_signature(conn) do
    case System.get_env("INBOX_WEBHOOK_SECRET") do
      value when value in [nil, ""] ->
        :ok

      secret ->
        do_verify(conn, secret)
    end
  end

  defp do_verify(conn, secret) do
    signature = get_req_header(conn, @signature_header) |> List.first()

    cond do
      is_nil(signature) ->
        {:error, "missing_signature"}

      is_nil(conn.assigns[:raw_body]) ->
        {:error, "raw_body_unavailable"}

      true ->
        expected =
          :crypto.mac(:hmac, :sha256, secret, conn.assigns[:raw_body])
          |> Base.encode16(case: :lower)

        provided = String.replace_prefix(signature, "sha256=", "")

        if Plug.Crypto.secure_compare(provided, expected),
          do: :ok,
          else: {:error, "signature_mismatch"}
    end
  end

  defp errors(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end
end
