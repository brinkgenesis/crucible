defmodule CrucibleWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use CrucibleWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint CrucibleWeb.Endpoint

      use CrucibleWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import CrucibleWeb.ConnCase
    end
  end

  setup tags do
    Crucible.DataCase.setup_sandbox(tags)

    # Ensure rate_limit ETS table exists and is cleared between tests
    # to prevent 429s when the full suite runs (all requests share 127.0.0.1)
    try do
      :ets.delete_all_objects(:rate_limit)
    rescue
      ArgumentError ->
        :ets.new(:rate_limit, [:duplicate_bag, :public, :named_table])
    end

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("content-type", "application/json")

    {:ok, conn: conn}
  end

  @doc "Add a partner-role user to the conn for authenticated API tests."
  def authenticate(conn) do
    conn =
      Plug.Conn.assign(conn, :current_user, %{
        id: "test-user",
        email: "test@test.com",
        role: "admin"
      })

    case Application.get_env(:crucible, :api_key) do
      nil -> conn
      api_key -> Plug.Conn.put_req_header(conn, "authorization", "Bearer #{api_key}")
    end
  end

  @doc """
  Runs a function in a context where API authentication is required.
  Since test.exs always configures an api_key, this is now a simple pass-through.
  Kept for backward compatibility with existing tests.
  """
  def with_auth_required(fun) do
    fun.()
  end
end
