defmodule Crucible.ElixirSdk.Mcp.Http do
  @moduledoc """
  MCP connection over HTTP.

  Supports the standard Streamable HTTP transport: POST JSON-RPC 2.0
  requests to the server's endpoint and read JSON-RPC replies back. We
  implement the non-streaming subset — each `call/3` is a single
  request/response round-trip. Extensions (SSE notifications from server)
  are a future addition.
  """

  use GenServer
  require Logger

  @behaviour Crucible.ElixirSdk.Mcp.Connection

  defstruct [:url, :headers, :server_name, next_id: 1]

  # ── Public API ─────────────────────────────────────────────────────────

  @impl true
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl true
  def call(pid, method, params \\ %{}) do
    GenServer.call(pid, {:rpc, method, params}, 60_000)
  end

  @impl true
  def close(pid), do: GenServer.stop(pid, :normal, 5_000)

  # ── GenServer ──────────────────────────────────────────────────────────

  @impl true
  def init(config) do
    url = Map.fetch!(config, :url)

    headers =
      Map.get(config, :headers, [])
      |> Enum.map(fn
        {k, v} when is_binary(k) -> {k, v}
        {k, v} -> {to_string(k), to_string(v)}
      end)
      |> Kernel.++([{"content-type", "application/json"}, {"accept", "application/json"}])

    {:ok,
     %__MODULE__{
       url: url,
       headers: headers,
       server_name: Map.get(config, :name, "unnamed")
     }}
  end

  @impl true
  def handle_call({:rpc, method, params}, _from, state) do
    id = state.next_id

    body = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }

    reply =
      case Req.post(state.url, json: body, headers: state.headers, receive_timeout: 60_000) do
        {:ok, %Req.Response{status: 200, body: %{"result" => result}}} ->
          {:ok, result}

        {:ok, %Req.Response{status: 200, body: %{"error" => error}}} ->
          {:error, error}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:http, status, inspect(body)}}

        {:error, reason} ->
          {:error, reason}
      end

    {:reply, reply, %{state | next_id: id + 1}}
  end
end
