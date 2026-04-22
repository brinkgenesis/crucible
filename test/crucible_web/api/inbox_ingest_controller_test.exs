defmodule CrucibleWeb.Api.InboxIngestControllerTest do
  use CrucibleWeb.ConnCase

  alias Crucible.Repo
  alias Crucible.Schema.InboxItem

  setup do
    # RateLimit plug requires an ETS table; create it defensively.
    try do
      :ets.new(:rate_limit, [:duplicate_bag, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    # Make sure INBOX_WEBHOOK_SECRET doesn't leak between tests.
    System.delete_env("INBOX_WEBHOOK_SECRET")
    on_exit(fn -> System.delete_env("INBOX_WEBHOOK_SECRET") end)

    :ok
  end

  # --- POST /api/v1/inbox/link (authenticated) ---

  describe "POST /api/v1/inbox/link" do
    test "inserts a new link and returns 201", %{conn: conn} do
      conn =
        conn
        |> authenticate()
        |> post("/api/v1/inbox/link", %{
          "url" => "https://example.com/a",
          "title" => "Pinned article",
          "note" => "Read this"
        })

      body = json_response(conn, 201)
      assert body["status"] == "inserted"
      assert body["url"] == "https://example.com/a"

      [item] = Repo.all(InboxItem)
      assert item.source == "link"
      assert item.title == "Pinned article"
      assert item.original_text == "Read this"
    end

    test "second submission returns 200 with status=skipped", %{conn: conn} do
      conn = authenticate(conn)

      _ =
        conn
        |> post("/api/v1/inbox/link", %{"url" => "https://example.com/dup", "title" => "T"})

      conn =
        conn
        |> post("/api/v1/inbox/link", %{"url" => "https://example.com/dup", "title" => "T"})

      body = json_response(conn, 200)
      assert body["status"] == "skipped"
    end

    test "rejects invalid urls with 400", %{conn: conn} do
      conn =
        conn
        |> authenticate()
        |> post("/api/v1/inbox/link", %{"url" => "not-a-url"})

      assert json_response(conn, 400)["error"] == "invalid_url"
    end

    test "rejects missing url with 400", %{conn: conn} do
      conn = conn |> authenticate() |> post("/api/v1/inbox/link", %{})
      assert json_response(conn, 400)["error"] == "url_required"
    end
  end

  # --- POST /api/v1/webhooks/inbox/receive (HMAC) ---

  describe "POST /api/v1/webhooks/inbox/receive — no secret set" do
    test "accepts unsigned payload when INBOX_WEBHOOK_SECRET is unset", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/webhooks/inbox/receive", %{
          "source_id" => "ext-1",
          "title" => "hello"
        })

      assert json_response(conn, 200)["status"] == "inserted"

      [item] = Repo.all(InboxItem)
      assert item.source == "webhook"
    end
  end

  describe "POST /api/v1/webhooks/inbox/receive — with secret" do
    setup do
      System.put_env("INBOX_WEBHOOK_SECRET", "s3cret")
      :ok
    end

    test "accepts valid HMAC-signed payload", %{conn: conn} do
      body = Jason.encode!(%{"source_id" => "ext-2", "title" => "signed"})
      sig = hmac("s3cret", body)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-crucible-signature-256", "sha256=" <> sig)
        |> post("/api/v1/webhooks/inbox/receive", body)

      assert json_response(conn, 200)["status"] == "inserted"
    end

    test "rejects payload with bad signature", %{conn: conn} do
      body = Jason.encode!(%{"source_id" => "ext-3"})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-crucible-signature-256", "sha256=deadbeef")
        |> post("/api/v1/webhooks/inbox/receive", body)

      assert json_response(conn, 401)["error"] == "unauthorized"
      assert Repo.aggregate(InboxItem, :count) == 0
    end

    test "rejects payload missing signature header", %{conn: conn} do
      body = Jason.encode!(%{"source_id" => "ext-4"})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/webhooks/inbox/receive", body)

      assert json_response(conn, 401)["error"] == "unauthorized"
    end
  end

  defp hmac(secret, body) do
    :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
  end
end
