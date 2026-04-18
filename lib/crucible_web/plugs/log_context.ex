defmodule CrucibleWeb.Plugs.LogContext do
  @moduledoc """
  Sets structured Logger metadata from request context.
  Should run after RequestId plug so request_id is already assigned.
  """
  alias Crucible.LoggerContext

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    LoggerContext.set_request_context(conn)
    conn
  end
end
