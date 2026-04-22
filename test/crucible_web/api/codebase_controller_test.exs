defmodule CrucibleWeb.Api.CodebaseControllerTest do
  use CrucibleWeb.ConnCase

  setup do
    try do
      :ets.new(:rate_limit, [:duplicate_bag, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  # ── GET /api/v1/codebase ─────────────────────────────────────────

  describe "GET /api/v1/codebase" do
    test "returns a list of codebase modules", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/codebase")
      body = json_response(conn, 200)
      assert is_list(body)

      for mod <- body do
        assert is_binary(mod["name"])
        assert is_binary(mod["path"])
      end
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
        conn = get(conn, "/api/v1/codebase")
        assert conn.status in [401, 503]
      end)
    end
  end

  # ── GET /api/v1/codebase/symbols ─────────────────────────────────

  describe "GET /api/v1/codebase/symbols" do
    test "returns empty list (stub)", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/codebase/symbols")
      body = json_response(conn, 200)
      assert body == []
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
        conn = get(conn, "/api/v1/codebase/symbols")
        assert conn.status in [401, 503]
      end)
    end
  end

  # ── GET /api/v1/codebase/references ──────────────────────────────

  describe "GET /api/v1/codebase/references" do
    test "returns empty list (stub)", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/codebase/references")
      body = json_response(conn, 200)
      assert body == []
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
        conn = get(conn, "/api/v1/codebase/references")
        assert conn.status in [401, 503]
      end)
    end
  end

  # ── GET /api/v1/codebase/callgraph ───────────────────────────────

  describe "GET /api/v1/codebase/callgraph" do
    test "returns nodes and edges structure", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/codebase/callgraph")
      body = json_response(conn, 200)
      assert body["nodes"] == []
      assert body["edges"] == []
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
        conn = get(conn, "/api/v1/codebase/callgraph")
        assert conn.status in [401, 503]
      end)
    end
  end

  # ── GET /api/v1/codebase/impact ──────────────────────────────────

  describe "GET /api/v1/codebase/impact" do
    test "returns dependents and transitives structure", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/codebase/impact")
      body = json_response(conn, 200)
      assert body["dependents"] == []
      assert body["transitives"] == []
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
        conn = get(conn, "/api/v1/codebase/impact")
        assert conn.status in [401, 503]
      end)
    end
  end

  # ── GET /api/v1/codebase/health ──────────────────────────────────

  describe "GET /api/v1/codebase/health" do
    test "returns score and violations structure", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/codebase/health")
      body = json_response(conn, 200)
      assert body["score"] == 0
      assert body["violations"] == []
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
        conn = get(conn, "/api/v1/codebase/health")
        assert conn.status in [401, 503]
      end)
    end
  end

  # ── GET /api/v1/codebase/graph ───────────────────────────────────

  describe "GET /api/v1/codebase/graph" do
    test "returns nodes and edges structure", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/codebase/graph")
      body = json_response(conn, 200)
      assert body["nodes"] == []
      assert body["edges"] == []
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
        conn = get(conn, "/api/v1/codebase/graph")
        assert conn.status in [401, 503]
      end)
    end
  end
end
