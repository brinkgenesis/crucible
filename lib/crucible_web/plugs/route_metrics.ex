defmodule CrucibleWeb.Plugs.RouteMetrics do
  @moduledoc """
  Records per-request API metrics for native health/SLO snapshots.
  """
  @behaviour Plug

  import Plug.Conn

  alias CrucibleWeb.RouteMetrics

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    started_at = System.monotonic_time()

    register_before_send(conn, fn conn ->
      duration_ms =
        System.monotonic_time()
        |> Kernel.-(started_at)
        |> System.convert_time_unit(:native, :microsecond)
        |> Kernel./(1_000)

      path = conn.private[:phoenix_route] || conn.request_path
      status = conn.status || 200
      RouteMetrics.record(conn.method, path, status, duration_ms)
      conn
    end)
  end
end
