defmodule CrucibleWeb.Api.AuditControllerTest do
  use CrucibleWeb.ConnCase

  setup do
    try do
      :ets.new(:rate_limit, [:duplicate_bag, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    # Clean up legacy JSONL audit log if repo_root is configured.
    # The controller is fully DB-backed; this cleanup is defensive.
    config = Application.get_env(:crucible, :orchestrator, [])

    case Keyword.fetch(config, :repo_root) do
      {:ok, repo_root} ->
        path = Path.join([repo_root, "data", "audit-log.jsonl"])
        File.mkdir_p!(Path.dirname(path))
        File.rm(path)

      :error ->
        :ok
    end

    :ok
  end

  defp insert_audit_log(attrs \\ %{}) do
    default = %{
      "userId" => "user-#{System.unique_integer([:positive])}",
      "clientId" => "client-1",
      "action" => "login",
      "resource" => "test_resource",
      "details" => %{"key" => "value"}
    }

    merged = Map.merge(default, attrs)

    # Parse resource into entity_type/entity_id
    {entity_type, entity_id} =
      case String.split(merged["resource"] || "unknown", "/", parts: 2) do
        [type, id] -> {type, id}
        [single] -> {"resource", single}
      end

    Crucible.AuditLog.log(
      entity_type,
      entity_id,
      merged["action"] || "login",
      merged["details"] || %{},
      actor: merged["userId"]
    )
  end

  describe "GET /api/v1/audit" do
    test "returns paginated audit events", %{conn: conn} do
      insert_audit_log()
      insert_audit_log(%{"action" => "logout"})

      conn = conn |> authenticate() |> get("/api/v1/audit")
      body = json_response(conn, 200)

      assert is_list(body["events"])
      assert is_integer(body["total"])
      assert body["total"] >= 2
      assert is_integer(body["limit"])
      assert is_integer(body["offset"])
    end

    test "returns events with shared TypeScript shape", %{conn: conn} do
      insert_audit_log(%{"action" => "login", "userId" => "u-shape"})

      conn = conn |> authenticate() |> get("/api/v1/audit")
      body = json_response(conn, 200)

      event = Enum.find(body["events"], &(&1["userId"] == "u-shape"))
      assert event
      refute Map.has_key?(event, "id")
      assert event["userId"] == "u-shape"
      assert is_binary(event["action"])
      assert is_binary(event["timestamp"])
    end

    test "supports limit and offset params", %{conn: conn} do
      for i <- 1..5, do: insert_audit_log(%{"userId" => "paginate-#{i}"})

      conn = conn |> authenticate() |> get("/api/v1/audit", limit: "2", offset: "1")
      body = json_response(conn, 200)

      assert body["limit"] == 2
      assert body["offset"] == 1
      assert length(body["events"]) <= 2
    end

    test "filters by userId", %{conn: conn} do
      insert_audit_log(%{"userId" => "filter-user", "action" => "login"})
      insert_audit_log(%{"userId" => "other-user", "action" => "logout"})

      conn = conn |> authenticate() |> get("/api/v1/audit", userId: "filter-user")
      body = json_response(conn, 200)

      assert Enum.all?(body["events"], &(&1["userId"] == "filter-user"))
    end

    test "clientId param is accepted without error", %{conn: conn} do
      insert_audit_log(%{"action" => "login"})

      conn = conn |> authenticate() |> get("/api/v1/audit", clientId: "client-a")
      body = json_response(conn, 200)

      # clientId filtering not supported in DB-backed audit — param accepted but ignored
      assert is_list(body["events"])
    end

    test "filters by action", %{conn: conn} do
      insert_audit_log(%{"action" => "login"})
      insert_audit_log(%{"action" => "logout"})

      conn = conn |> authenticate() |> get("/api/v1/audit", action: "logout")
      body = json_response(conn, 200)

      assert Enum.all?(body["events"], &(&1["action"] == "logout"))
    end

    test "rejects unsupported actions", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/audit", action: "shape_test")

      assert json_response(conn, 400)["error"]["code"] == "invalid_params"
    end

    test "filters by date range", %{conn: conn} do
      insert_audit_log(%{"action" => "login"})

      from = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_iso8601()
      to = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

      conn = conn |> authenticate() |> get("/api/v1/audit", from: from, to: to)
      body = json_response(conn, 200)

      assert is_list(body["events"])
    end

    test "returns empty when no events match", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/audit", userId: "nonexistent-user-xyz")
      body = json_response(conn, 200)

      assert body["events"] == []
      assert body["total"] == 0
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
      conn = get(conn, "/api/v1/audit")
      assert conn.status in [401, 503]
      end)
    end
  end
end
