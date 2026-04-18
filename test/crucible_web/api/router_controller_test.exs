defmodule CrucibleWeb.Api.RouterControllerTest do
  use CrucibleWeb.ConnCase

  setup do
    try do
      :ets.new(:rate_limit, [:duplicate_bag, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  # --- GET /api/v1/router/models ---

  describe "GET /api/v1/router/models" do
    test "returns the hardcoded model map", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/router/models")
      body = json_response(conn, 200)

      assert is_map(body)
      assert Map.has_key?(body, "claude-opus-4")
      assert Map.has_key?(body, "claude-sonnet-4")
      assert Map.has_key?(body, "claude-haiku-3.5")
      assert Map.has_key?(body, "gemini-2.0-flash")
      assert Map.has_key?(body, "minimax-m2")

      opus = body["claude-opus-4"]
      assert opus["provider"] == "anthropic"
      assert opus["inputPerMillion"] == 15.0
      assert opus["outputPerMillion"] == 75.0
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
      conn = get(conn, "/api/v1/router/models")
      assert conn.status in [401, 503]
      end)
    end
  end

  # --- GET /api/v1/router/health ---

  describe "GET /api/v1/router/health" do
    test "returns provider health booleans", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/router/health")
      body = json_response(conn, 200)

      assert is_map(body)

      Enum.each(body, fn {_provider, healthy} ->
        assert is_boolean(healthy)
      end)
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
      conn = get(conn, "/api/v1/router/health")
      assert conn.status in [401, 503]
      end)
    end
  end

  # --- GET /api/v1/router/circuits ---

  describe "GET /api/v1/router/circuits" do
    test "returns circuit breaker state map", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/router/circuits")
      body = json_response(conn, 200)
      assert is_map(body)
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
      conn = get(conn, "/api/v1/router/circuits")
      assert conn.status in [401, 503]
      end)
    end
  end

  # --- POST /api/v1/router/circuits/:provider/reset ---

  describe "POST /api/v1/router/circuits/:provider/reset" do
    test "resets circuit breaker to closed", %{conn: conn} do
      conn = conn |> authenticate() |> post("/api/v1/router/circuits/anthropic/reset")
      body = json_response(conn, 200)

      assert body["status"] == "ok"
      assert body["provider"] == "anthropic"
      assert body["state"] == "closed"
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
      conn = post(conn, "/api/v1/router/circuits/anthropic/reset")
      assert conn.status in [401, 503]
      end)
    end
  end

end
