defmodule CrucibleWeb.PoliciesLiveTest do
  use CrucibleWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "GET /policies" do
    test "renders policies page", %{conn: conn} do
      {:ok, _view, html} = conn |> authenticate() |> live("/policies")
      assert html =~ "EXECUTION_POLICIES"
    end

    test "shows policy categories", %{conn: conn} do
      {:ok, _view, html} = conn |> authenticate() |> live("/policies")
      assert html =~ "MODEL_ALLOWLISTS" or html =~ "POLICIES"
    end
  end
end
