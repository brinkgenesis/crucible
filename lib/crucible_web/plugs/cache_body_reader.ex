defmodule CrucibleWeb.Plugs.CacheBodyReader do
  @moduledoc """
  Custom body reader for `Plug.Parsers` that stashes the raw request body on
  `conn.assigns[:raw_body]` for webhook routes that need HMAC verification.

  We only cache for the configured prefixes so we don't double-hold every
  JSON body in memory. Wire via `body_reader:` in the endpoint's
  `Plug.Parsers` plug.
  """

  @cache_prefixes ["/api/v1/webhooks/"]

  @spec read_body(Plug.Conn.t(), keyword()) :: {:ok, binary(), Plug.Conn.t()}
  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)

    conn =
      if String.starts_with?(conn.request_path, @cache_prefixes) do
        Plug.Conn.assign(conn, :raw_body, body)
      else
        conn
      end

    {:ok, body, conn}
  end
end
