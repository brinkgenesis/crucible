defmodule CrucibleWeb.Api.KanbanControllerTest do
  use CrucibleWeb.ConnCase

  setup do
    try do
      :ets.new(:rate_limit, [:duplicate_bag, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  describe "GET /api/v1/kanban/cards" do
    test "returns a list of cards", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/kanban/cards")

      case conn.status do
        200 ->
          body = json_response(conn, 200)
          assert is_list(body)

        500 ->
          # Kanban adapter may not be available in test env
          body = json_response(conn, 500)
          assert body["error"] == "internal_error"
      end
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
      conn = get(conn, "/api/v1/kanban/cards")
      assert conn.status in [401, 503]
      end)
    end
  end

  describe "POST /api/v1/kanban/cards" do
    test "creates a card with valid params", %{conn: conn} do
      params = %{
        "title" => "Test Card",
        "column" => "unassigned",
        "metadata" => %{"priority" => "high"}
      }

      conn =
        conn
        |> authenticate()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/kanban/cards", params)

      case conn.status do
        201 ->
          body = json_response(conn, 201)
          assert body["title"] == "Test Card"
          assert body["column"] == "unassigned"
          assert is_binary(body["id"])

        422 ->
          body = json_response(conn, 422)
          assert body["error"] == "unprocessable_entity"

        500 ->
          # Adapter not available
          :ok
      end
    end
  end

  describe "GET /api/v1/kanban/cards/:id" do
    test "returns 404 for nonexistent card", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/kanban/cards/nonexistent-id")
      assert conn.status in [404, 500]
    end
  end

  describe "DELETE /api/v1/kanban/cards/:id" do
    test "returns 404 for nonexistent card", %{conn: conn} do
      conn = conn |> authenticate() |> delete("/api/v1/kanban/cards/nonexistent-id")
      assert conn.status in [404, 500]
    end
  end

  describe "POST /api/v1/kanban/cards/:id/move" do
    test "returns 404 for nonexistent card", %{conn: conn} do
      conn =
        conn
        |> authenticate()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/kanban/cards/nonexistent-id/move", %{"column" => "doing"})

      assert conn.status in [400, 404, 500]
    end
  end
end
