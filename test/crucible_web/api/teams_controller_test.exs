defmodule CrucibleWeb.Api.TeamsControllerTest do
  use CrucibleWeb.ConnCase

  setup do
    try do
      :ets.new(:rate_limit, [:duplicate_bag, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  # --- GET /api/v1/teams ---

  describe "GET /api/v1/teams" do
    test "returns a list of teams", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/teams")
      body = json_response(conn, 200)

      assert is_list(body)
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
      conn = get(conn, "/api/v1/teams")
      assert conn.status in [401, 503]
      end)
    end
  end

  # --- GET /api/v1/teams/:name ---

  describe "GET /api/v1/teams/:name" do
    test "returns 404 for nonexistent team", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/teams/nonexistent-team-xyz")
      body = json_response(conn, 404)

      assert body["error"] == "not_found"
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
      conn = get(conn, "/api/v1/teams/some-team")
      assert conn.status in [401, 503]
      end)
    end
  end

  # --- GET /api/v1/teams/:name/members ---

  describe "GET /api/v1/teams/:name/members" do
    test "returns empty list for nonexistent team", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/teams/nonexistent-team-xyz/members")
      body = json_response(conn, 200)

      # read_team_config returns %{} for missing teams, Map.get(%{}, "members", []) => []
      assert is_list(body)
      assert body == []
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
      conn = get(conn, "/api/v1/teams/some-team/members")
      assert conn.status in [401, 503]
      end)
    end
  end

  # --- GET /api/v1/teams/:name/tasks ---

  describe "GET /api/v1/teams/:name/tasks" do
    test "returns empty list for nonexistent team", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/teams/nonexistent-team-xyz/tasks")
      body = json_response(conn, 200)

      # tasks_dir won't exist for a missing team, returns []
      assert is_list(body)
      assert body == []
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
      conn = get(conn, "/api/v1/teams/some-team/tasks")
      assert conn.status in [401, 503]
      end)
    end
  end

end
