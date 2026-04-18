defmodule CrucibleWeb.Plugs.CopySidToSession do
  @moduledoc """
  Copies the plain "sid" cookie value into the Phoenix session
  so that LiveView on_mount hooks can access it.

  LiveView connect_info only gets the Phoenix session (signed cookie),
  not individual cookies. This plug bridges that gap.
  """
  import Plug.Conn

  @behaviour Plug
  @sid_cookie "sid"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_cookies(conn)

    case conn.cookies[@sid_cookie] do
      nil -> delete_session(conn, "_sid")
      sid -> put_session(conn, "_sid", sid)
    end
  end
end
