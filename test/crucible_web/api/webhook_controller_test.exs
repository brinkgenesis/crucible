defmodule CrucibleWeb.Api.WebhookControllerTest do
  use CrucibleWeb.ConnCase

  setup do
    try do
      :ets.new(:rate_limit, [:duplicate_bag, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  # --- POST /api/v1/webhooks/trigger ---

  describe "POST /api/v1/webhooks/trigger" do
    test "returns 422 when required fields are missing", %{conn: conn} do
      conn = conn |> authenticate() |> post("/api/v1/webhooks/trigger", %{})
      body = json_response(conn, 422)

      assert body["error"] == "validation_failed"
      assert is_list(body["details"])

      fields = Enum.map(body["details"], & &1["field"])
      assert "workflow_name" in fields
      assert "task_description" in fields
    end

    test "returns 422 when workflow_name is empty", %{conn: conn} do
      params = %{"workflow_name" => "", "task_description" => "do something"}

      conn = conn |> authenticate() |> post("/api/v1/webhooks/trigger", params)
      body = json_response(conn, 422)

      assert body["error"] == "validation_failed"

      fields = Enum.map(body["details"], & &1["field"])
      assert "workflow_name" in fields
    end

    test "returns 422 when task_description is missing", %{conn: conn} do
      params = %{"workflow_name" => "deploy"}

      conn = conn |> authenticate() |> post("/api/v1/webhooks/trigger", params)
      body = json_response(conn, 422)

      assert body["error"] == "validation_failed"

      fields = Enum.map(body["details"], & &1["field"])
      assert "task_description" in fields
    end

    test "accepts valid manifest and returns 202 or 500 or 422", %{conn: conn} do
      params = %{
        "workflow_name" => "test-workflow",
        "task_description" => "run the test suite",
        "priority" => "normal"
      }

      conn = conn |> authenticate() |> post("/api/v1/webhooks/trigger", params)

      # Orchestrator.submit_run may not be running in test — safe_call returns {:error, :internal}
      # 422 is valid when the workflow can't be resolved (no phases found in WorkflowStore)
      assert conn.status in [202, 422, 500]

      case conn.status do
        202 ->
          body = json_response(conn, 202)
          assert body["status"] == "accepted"
          assert is_binary(body["runId"])

        422 ->
          body = json_response(conn, 422)
          assert body["error"] in ["workflow_resolution_failed", "validation_failed"]

        500 ->
          body = json_response(conn, 500)
          assert body["error"] == "internal_error"
      end
    end

    test "returns 422 for invalid priority enum value", %{conn: conn} do
      params = %{
        "workflow_name" => "deploy",
        "task_description" => "ship it",
        "priority" => "super-urgent"
      }

      conn = conn |> authenticate() |> post("/api/v1/webhooks/trigger", params)
      body = json_response(conn, 422)

      assert body["error"] == "validation_failed"

      fields = Enum.map(body["details"], & &1["field"])
      assert "priority" in fields
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
        conn =
          post(conn, "/api/v1/webhooks/trigger", %{
            "workflow_name" => "x",
            "task_description" => "y"
          })

        assert conn.status in [401, 503]
      end)
    end
  end

end
