defmodule CrucibleWeb.ErrorJSONTest do
  use CrucibleWeb.ConnCase, async: true

  test "renders 404" do
    result = CrucibleWeb.ErrorJSON.render("404.json", %{})
    assert %{error: %{code: "not_found", message: _}} = result
  end

  test "renders 500" do
    result = CrucibleWeb.ErrorJSON.render("500.json", %{})
    assert %{error: %{code: "internal_error", message: _}} = result
  end
end
