defmodule CrucibleWeb.Plugs.ValidateContentType do
  @moduledoc """
  Enforces `application/json` Content-Type on write requests.

  POST, PUT, and PATCH requests must include a `Content-Type: application/json`
  header (parameters such as `; charset=utf-8` are accepted). Requests that
  fail the check are rejected with HTTP 415 Unsupported Media Type.

  GET, HEAD, and DELETE requests pass through unchanged.
  """
  import Plug.Conn

  @behaviour Plug

  @write_methods ~w(POST PUT PATCH)
  @required_type "application/json"

  @spec init(keyword()) :: keyword()
  @impl true
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  @impl true
  def call(conn, _opts) do
    if conn.method in @write_methods do
      validate(conn)
    else
      conn
    end
  end

  defp validate(conn) do
    content_type =
      conn
      |> get_req_header("content-type")
      |> List.first("")
      |> strip_parameters()

    if content_type == @required_type do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        415,
        Jason.encode!(%{
          error: "unsupported_media_type",
          message: "Content-Type must be application/json"
        })
      )
      |> halt()
    end
  end

  # Drop "; charset=utf-8" and similar parameter suffixes
  defp strip_parameters(content_type) do
    content_type
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.downcase()
  end
end
