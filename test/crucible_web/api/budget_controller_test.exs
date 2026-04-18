defmodule CrucibleWeb.Api.BudgetControllerTest do
  use CrucibleWeb.ConnCase, async: false

  describe "GET /api/budget/status" do
    test "returns budget status", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/budget/status")
      body = json_response(conn, 200)

      assert Map.has_key?(body, "dailySpent")
      assert Map.has_key?(body, "dailyLimit")
      assert Map.has_key?(body, "dailyRemaining")
      assert is_boolean(body["isOverBudget"])
      assert is_integer(body["eventCount"])
    end
  end

  describe "GET /api/budget/history" do
    test "returns daily spend history", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/budget/history?days=3")
      body = json_response(conn, 200)

      assert is_list(body)
    end
  end

  describe "GET /api/budget/breakdown" do
    test "returns model breakdown", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/budget/breakdown")
      body = json_response(conn, 200)

      assert is_list(body)
    end
  end
end
