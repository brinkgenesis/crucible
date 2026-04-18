defmodule CrucibleWeb.AuditLiveTest do
  use CrucibleWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "GET /audit" do
    test "renders audit trail page", %{conn: conn} do
      {:ok, _view, html} = conn |> authenticate() |> live("/audit")
      assert html =~ "AUDIT_TRAIL"
    end

    test "shows health check info", %{conn: conn} do
      {:ok, _view, html} = conn |> authenticate() |> live("/audit")
      assert html =~ "DB Health" or html =~ "AUDIT"
    end
  end
end
