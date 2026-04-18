defmodule CrucibleWeb.Plugs.RequestId do
  @moduledoc """
  Assigns a unique request ID to every request for log correlation.
  Uses X-Request-ID header if provided by client, otherwise generates one.
  Propagates via Logger metadata and response header.
  """
  import Plug.Conn
  require Logger

  @behaviour Plug

  @max_client_id_length 200

  @spec init(keyword()) :: keyword()
  @impl true
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  @impl true
  def call(conn, _opts) do
    request_id = resolve_request_id(conn)

    Logger.metadata(request_id: request_id)

    conn
    |> assign(:request_id, request_id)
    |> put_resp_header("x-request-id", request_id)
  end

  defp resolve_request_id(conn) do
    case get_req_header(conn, "x-request-id") do
      [id] when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= @max_client_id_length ->
        id

      _ ->
        generate_id()
    end
  end

  defp generate_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
