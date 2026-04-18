defmodule Crucible.ElixirSdk.Mcp.Stdio do
  @moduledoc """
  MCP subprocess transport over stdio.

  Launches the configured `command` with `args`, opens a Port, and routes
  JSON-RPC 2.0 frames (each frame is one JSON object on one line).
  Requests block via `GenServer.call` until the server answers with a
  matching `id`.

  Framing: MCP over stdio uses LSP-style `Content-Length: n\\r\\n\\r\\n{json}`.
  We implement that explicitly.
  """

  use GenServer
  require Logger

  @behaviour Crucible.ElixirSdk.Mcp.Connection

  defstruct [:port, :os_pid, :server_name, buffer: "", pending: %{}, next_id: 1]

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
    Process.flag(:trap_exit, true)
    command = Map.fetch!(config, :command)
    args = Map.get(config, :args, [])
    env = build_env(Map.get(config, :env, %{}))

    exe = System.find_executable(command) || command

    port =
      Port.open(
        {:spawn_executable, exe},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:args, args},
          {:env, env}
        ]
      )

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    state = %__MODULE__{
      port: port,
      os_pid: os_pid,
      server_name: Map.get(config, :name, "unnamed")
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:rpc, method, params}, from, state) do
    id = state.next_id
    frame = encode_frame(id, method, params)
    Port.command(state.port, frame)

    pending = Map.put(state.pending, id, from)
    {:noreply, %{state | pending: pending, next_id: id + 1}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> to_string(data)
    {messages, leftover} = extract_messages(buffer)

    state = %{state | buffer: leftover}

    state =
      Enum.reduce(messages, state, fn msg, acc ->
        dispatch_message(msg, acc)
      end)

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("Mcp.Stdio[#{state.server_name}]: subprocess exited (#{status})")

    Enum.each(state.pending, fn {_id, from} ->
      GenServer.reply(from, {:error, {:server_exited, status}})
    end)

    {:stop, :normal, %{state | port: nil, pending: %{}}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_port(state.port), do: safe_close_port(state.port)

    if is_integer(state.os_pid) do
      try do
        System.cmd("kill", ["-9", Integer.to_string(state.os_pid)], stderr_to_stdout: true)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  # ── JSON-RPC framing ───────────────────────────────────────────────────

  defp encode_frame(id, method, params) do
    body =
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => params
      }
      |> Jason.encode!()

    "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
  end

  # Parse the running buffer for complete `Content-Length: N\r\n\r\n<body>`
  # frames. Returns `{messages, leftover}`.
  defp extract_messages(buffer), do: extract_messages(buffer, [])

  defp extract_messages(buffer, acc) do
    case :binary.split(buffer, "\r\n\r\n") do
      [_only] ->
        {Enum.reverse(acc), buffer}

      [headers, rest] ->
        case parse_content_length(headers) do
          {:ok, len} when byte_size(rest) >= len ->
            body = binary_part(rest, 0, len)
            remaining = binary_part(rest, len, byte_size(rest) - len)

            case Jason.decode(body) do
              {:ok, msg} -> extract_messages(remaining, [msg | acc])
              _ -> extract_messages(remaining, acc)
            end

          {:ok, _} ->
            {Enum.reverse(acc), buffer}

          :error ->
            {Enum.reverse(acc), rest}
        end
    end
  end

  defp parse_content_length(headers) do
    case Regex.run(~r/Content-Length:\s*(\d+)/i, headers) do
      [_, n] -> {:ok, String.to_integer(n)}
      _ -> :error
    end
  end

  defp dispatch_message(%{"id" => id, "result" => result}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {from, pending} ->
        GenServer.reply(from, {:ok, result})
        %{state | pending: pending}
    end
  end

  defp dispatch_message(%{"id" => id, "error" => error}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {from, pending} ->
        GenServer.reply(from, {:error, error})
        %{state | pending: pending}
    end
  end

  defp dispatch_message(_notification, state), do: state

  # ── helpers ─────────────────────────────────────────────────────────────

  defp build_env(map) when is_map(map) do
    # Pass through a safe PATH and any user-supplied vars.
    system_path = System.get_env("PATH") || ""
    pairs = [{"PATH", system_path}] ++ Map.to_list(map)

    Enum.map(pairs, fn {k, v} ->
      {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
    end)
  end

  defp safe_close_port(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end
  end
end
