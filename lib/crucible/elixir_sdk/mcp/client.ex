defmodule Crucible.ElixirSdk.Mcp.Client do
  @moduledoc """
  MCP client manager.

  Reads `:crucible, :mcp_servers` configuration, launches one connection
  per server (stdio or http), performs the initialisation handshake, and
  discovers each server's tool list. Connections are supervised under
  `Crucible.ElixirSdk.Mcp.Supervisor`.

  Configuration shape (example in `config.exs`):

      config :crucible, :mcp_servers, [
        %{
          name: "filesystem",
          transport: :stdio,
          command: "npx",
          args: ["@modelcontextprotocol/server-filesystem", "/tmp"],
          env: %{}
        },
        %{
          name: "weather",
          transport: :http,
          url: "https://example.com/mcp"
        }
      ]

  At boot each server is initialised with:

      initialize   → confirm protocol version + advertise capabilities
      tools/list   → enumerate available tools
      notifications/initialized → tell server we're ready

  Tool names are prefixed with `mcp__{server}__` in the registry to avoid
  collisions with Crucible's built-in tools. The same prefix is used when
  routing tool calls back to the right server.
  """

  use GenServer
  require Logger

  alias Crucible.ElixirSdk.Mcp.{Http, Stdio}

  @protocol_version "2025-06-18"

  defstruct servers: %{}, tools: %{}

  # ── Public API ─────────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Returns `[{\"mcp__server__tool\", schema_map}, ...]` from all servers."
  def registered_tools do
    case Process.whereis(__MODULE__) do
      nil -> []
      pid -> GenServer.call(pid, :tools, 10_000)
    end
  end

  @doc "Invoke an MCP tool. Name must be a full `mcp__server__tool` id."
  def call_tool(name, arguments) when is_binary(name) do
    case parse_tool_name(name) do
      {:ok, server, tool} ->
        case GenServer.call(__MODULE__, {:call_tool, server, tool, arguments}, 60_000) do
          {:ok, %{"content" => content}} -> {:ok, render_content(content)}
          {:ok, other} -> {:ok, inspect(other)}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:error, "invalid MCP tool name: #{name}"}
    end
  end

  @doc "Reload configuration; tears down servers no longer listed."
  def reload, do: GenServer.call(__MODULE__, :reload, 30_000)

  # ── GenServer ─────────────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    state = %__MODULE__{}
    {:ok, state, {:continue, :boot_servers}}
  end

  @impl true
  def handle_continue(:boot_servers, state) do
    {:noreply, boot(state)}
  end

  @impl true
  def handle_call(:tools, _from, state) do
    tools =
      Enum.flat_map(state.tools, fn {server, tool_list} ->
        Enum.map(tool_list, fn tool ->
          name = "mcp__#{server}__#{tool["name"]}"

          {name,
           %{
             name: name,
             description: Map.get(tool, "description", ""),
             input_schema: Map.get(tool, "inputSchema", %{type: "object"})
           }}
        end)
      end)

    {:reply, tools, state}
  end

  def handle_call({:call_tool, server, tool, arguments}, _from, state) do
    case Map.get(state.servers, server) do
      nil ->
        {:reply, {:error, "unknown MCP server: #{server}"}, state}

      %{pid: pid, module: module} ->
        reply = module.call(pid, "tools/call", %{"name" => tool, "arguments" => arguments})
        {:reply, reply, state}
    end
  end

  def handle_call(:reload, _from, state) do
    shutdown(state)
    {:reply, :ok, boot(%__MODULE__{})}
  end

  @impl true
  def terminate(_reason, state), do: shutdown(state)

  # ── internals ──────────────────────────────────────────────────────────

  defp boot(_state) do
    configs = Application.get_env(:crucible, :mcp_servers, [])

    servers =
      configs
      |> Enum.map(&start_server/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.into(%{}, fn {name, info} -> {name, info} end)

    tools =
      servers
      |> Enum.into(%{}, fn {name, %{pid: pid, module: module}} ->
        {name, list_tools(module, pid, name)}
      end)

    Logger.info(
      "Mcp.Client: booted #{map_size(servers)} servers with #{count_tools(tools)} tools"
    )

    %__MODULE__{servers: servers, tools: tools}
  end

  defp start_server(%{name: name, transport: :stdio} = config) do
    case Stdio.start_link(config) do
      {:ok, pid} ->
        handshake(Stdio, pid)
        {name, %{pid: pid, module: Stdio, config: config}}

      {:error, reason} ->
        Logger.warning("Mcp.Client: failed to start stdio server #{name}: #{inspect(reason)}")
        nil
    end
  end

  defp start_server(%{name: name, transport: :http} = config) do
    case Http.start_link(config) do
      {:ok, pid} ->
        handshake(Http, pid)
        {name, %{pid: pid, module: Http, config: config}}

      {:error, reason} ->
        Logger.warning("Mcp.Client: failed to start http server #{name}: #{inspect(reason)}")
        nil
    end
  end

  defp start_server(config) do
    Logger.warning("Mcp.Client: skipping malformed server config: #{inspect(config)}")
    nil
  end

  defp handshake(module, pid) do
    # Announce ourselves as a client speaking the current MCP protocol.
    case module.call(pid, "initialize", %{
           "protocolVersion" => @protocol_version,
           "capabilities" => %{"tools" => %{}},
           "clientInfo" => %{"name" => "crucible", "version" => "0.1.0"}
         }) do
      {:ok, _} ->
        _ = module.call(pid, "notifications/initialized", %{})
        :ok

      {:error, reason} ->
        Logger.warning("Mcp.Client: initialize failed: #{inspect(reason)}")
        :error
    end
  end

  defp list_tools(module, pid, name) do
    case module.call(pid, "tools/list", %{}) do
      {:ok, %{"tools" => tools}} when is_list(tools) ->
        tools

      {:ok, other} ->
        Logger.warning("Mcp.Client[#{name}]: unexpected tools/list result: #{inspect(other)}")
        []

      {:error, reason} ->
        Logger.warning("Mcp.Client[#{name}]: tools/list failed: #{inspect(reason)}")
        []
    end
  end

  defp count_tools(tools_by_server) do
    tools_by_server |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
  end

  defp shutdown(%{servers: servers}) do
    Enum.each(servers, fn {_, %{pid: pid, module: module}} ->
      try do
        module.close(pid)
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  defp shutdown(_), do: :ok

  defp parse_tool_name("mcp__" <> rest) do
    case String.split(rest, "__", parts: 2) do
      [server, tool] when server != "" and tool != "" -> {:ok, server, tool}
      _ -> :error
    end
  end

  defp parse_tool_name(_), do: :error

  defp render_content(items) when is_list(items) do
    items
    |> Enum.map_join("\n", fn
      %{"type" => "text", "text" => t} -> t
      %{"type" => "image", "data" => _} -> "[image]"
      other -> inspect(other)
    end)
  end

  defp render_content(other), do: inspect(other)
end
