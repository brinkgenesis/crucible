defmodule CrucibleWeb.Api.ConfigControllerTest do
  use CrucibleWeb.ConnCase, async: false

  setup do
    previous_orchestrator = Application.get_env(:crucible, :orchestrator, [])

    try do
      :ets.new(:rate_limit, [:duplicate_bag, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    on_exit(fn ->
      Application.put_env(:crucible, :orchestrator, previous_orchestrator)
    end)

    :ok
  end

  describe "GET /api/v1/config" do
    test "returns current config", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/config")
      body = json_response(conn, 200)
      assert is_map(body)
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
        conn = get(conn, "/api/v1/config")
        assert conn.status in [401, 503]
      end)
    end
  end

  describe "GET /api/v1/config/budget" do
    test "returns budget config", %{conn: conn} do
      Application.put_env(:crucible, :orchestrator,
        daily_budget_usd: 111.0,
        agent_budget_usd: 22.0,
        task_budget_usd: 33.0
      )

      conn = conn |> authenticate() |> get("/api/v1/config/budget")
      body = json_response(conn, 200)
      assert body["dailyLimit"] == 111.0
      assert body["agentLimit"] == 22.0
      assert body["taskLimit"] == 33.0
    end
  end

  describe "GET /api/v1/config/env" do
    test "redacts sensitive values", %{conn: conn} do
      System.put_env("DATABASE_URL", "ecto://secret")
      on_exit(fn -> System.delete_env("DATABASE_URL") end)

      conn = conn |> authenticate() |> get("/api/v1/config/env")
      body = json_response(conn, 200)
      assert body["DATABASE_URL"] == "***"
    end
  end

  describe "PUT /api/v1/config/budget" do
    test "validates budget parameters — rejects invalid values", %{conn: conn} do
      conn =
        conn
        |> authenticate()
        |> put_req_header("content-type", "application/json")
        |> put("/api/v1/config/budget", %{"dailyLimit" => "not-a-number"})

      assert conn.status == 422
      body = json_response(conn, 422)
      assert body["error"] == "validation_error"
    end

    test "validates budget parameters — rejects negative values", %{conn: conn} do
      conn =
        conn
        |> authenticate()
        |> put_req_header("content-type", "application/json")
        |> put("/api/v1/config/budget", %{"dailyLimit" => -5.0})

      assert conn.status == 422
    end

    test "accepts valid budget parameters", %{conn: conn} do
      conn =
        conn
        |> authenticate()
        |> put_req_header("content-type", "application/json")
        |> put("/api/v1/config/budget", %{"dailyLimit" => 50.0})

      body = json_response(conn, 200)
      assert body["ok"] == true

      assert Keyword.get(Application.get_env(:crucible, :orchestrator, []), :daily_budget_usd) ==
               50.0
    end
  end
end
