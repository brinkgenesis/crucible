defmodule CrucibleWeb.Api.RemoteControllerTest do
  use CrucibleWeb.ConnCase

  setup do
    try do
      :ets.new(:rate_limit, [:duplicate_bag, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    # Ensure tracker state is reset between tests.
    _ = Crucible.RemoteSessionTracker.stop_session()
    wait_until_remote_stopped(8)

    :ok
  end

  defp wait_until_remote_stopped(0), do: :ok

  defp wait_until_remote_stopped(attempts) do
    case Crucible.RemoteSessionTracker.status() do
      %{running: true} ->
        Process.sleep(25)
        _ = Crucible.RemoteSessionTracker.stop_session()
        wait_until_remote_stopped(attempts - 1)

      _ ->
        :ok
    end
  end

  # ── POST /api/v1/remote/start ────────────────────────────────────

  describe "POST /api/v1/remote/start" do
    test "starts a remote session or fails gracefully", %{conn: conn} do
      conn = conn |> authenticate() |> post("/api/v1/remote/start")
      # The Port.open may fail in test since `claude` binary may not exist
      assert conn.status in [200, 500]

      case conn.status do
        200 ->
          body = json_response(conn, 200)
          assert body["running"] == true
          assert is_binary(body["startedAt"])

        500 ->
          body = json_response(conn, 500)
          assert body["error"] == "start_failed"
      end
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
      conn = post(conn, "/api/v1/remote/start")
      assert conn.status in [401, 503]
      end)
    end
  end

  # ── GET /api/v1/remote/status ────────────────────────────────────

  describe "GET /api/v1/remote/status" do
    test "returns status when no session is running", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/remote/status")
      body = json_response(conn, 200)

      assert body["running"] == false
    end

    test "returns running status fields when present", %{conn: conn} do
      conn = conn |> authenticate() |> get("/api/v1/remote/status")
      body = json_response(conn, 200)

      assert is_boolean(body["running"])
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
      conn = get(conn, "/api/v1/remote/status")
      assert conn.status in [401, 503]
      end)
    end
  end

  # ── POST /api/v1/remote/stop ─────────────────────────────────────

  describe "POST /api/v1/remote/stop" do
    test "returns stop result when no session is running", %{conn: conn} do
      conn = conn |> authenticate() |> post("/api/v1/remote/stop")
      body = json_response(conn, 200)

      assert body["stopped"] == false
      assert body["wasRunning"] == false
    end

    test "requires authentication", %{conn: conn} do
      with_auth_required(fn ->
      conn = post(conn, "/api/v1/remote/stop")
      assert conn.status in [401, 503]
      end)
    end
  end
end
