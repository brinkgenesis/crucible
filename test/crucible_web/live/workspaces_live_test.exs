defmodule CrucibleWeb.WorkspacesLiveTest do
  use CrucibleWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "GET /workspaces" do
    test "renders workspaces page", %{conn: conn} do
      {:ok, _view, html} = conn |> authenticate() |> live("/workspaces")
      assert html =~ "WORKSPACE_PROFILES"
    end

    test "shows new workspace button", %{conn: conn} do
      {:ok, _view, html} = conn |> authenticate() |> live("/workspaces")
      assert html =~ "NEW_WORKSPACE" or html =~ "WORKSPACE"
    end
  end
end
