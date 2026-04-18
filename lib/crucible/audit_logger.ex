defmodule Crucible.AuditLogger do
  @moduledoc """
  Writes structured auth/security events to audit.jsonl.
  Attaches telemetry handlers for auth failures, rate limit hits, and session events.
  """
  use GenServer
  require Logger

  @default_handler_prefix "audit-logger"

  # --- Client API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec log(GenServer.server(), atom(), map()) :: :ok
  def log(server \\ __MODULE__, event_type, metadata \\ %{}) do
    GenServer.cast(server, {:log, event_type, metadata})
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    log_dir = Keyword.get(opts, :log_dir, default_log_dir())
    handler_prefix = Keyword.get(opts, :handler_prefix, @default_handler_prefix)
    File.mkdir_p!(log_dir)
    path = Path.join(log_dir, "audit.jsonl")

    server_name = Keyword.get(opts, :name, __MODULE__)
    attach_telemetry_handlers(handler_prefix, server_name)

    {:ok, %{path: path, handler_prefix: handler_prefix}}
  end

  @impl true
  def handle_cast({:log, event_type, metadata}, state) do
    entry = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      event: event_type,
      metadata: metadata
    }

    case Jason.encode(entry) do
      {:ok, json} ->
        File.write(state.path, json <> "\n", [:append])

      {:error, reason} ->
        Logger.warning("AuditLogger encode failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    prefix = Map.get(state, :handler_prefix, @default_handler_prefix)
    :telemetry.detach("#{prefix}-auth-failure")
    :telemetry.detach("#{prefix}-rate-limit")
    :telemetry.detach("#{prefix}-session-login")
    :telemetry.detach("#{prefix}-session-logout")
    :ok
  end

  # --- Private ---

  defp attach_telemetry_handlers(prefix, server_name) do
    :telemetry.attach(
      "#{prefix}-auth-failure",
      [:crucible, :auth, :failure],
      &__MODULE__.handle_telemetry_event/4,
      %{server: server_name}
    )

    :telemetry.attach(
      "#{prefix}-rate-limit",
      [:crucible, :rate_limit, :hit],
      &__MODULE__.handle_telemetry_event/4,
      %{server: server_name}
    )

    :telemetry.attach(
      "#{prefix}-session-login",
      [:crucible, :session, :login],
      &__MODULE__.handle_telemetry_event/4,
      %{server: server_name}
    )

    :telemetry.attach(
      "#{prefix}-session-logout",
      [:crucible, :session, :logout],
      &__MODULE__.handle_telemetry_event/4,
      %{server: server_name}
    )
  end

  # Known telemetry event names — whitelist to avoid atom table exhaustion.
  # New telemetry events must be added here.
  @known_events %{
    "crucible.auth.failure" => :auth_failure,
    "crucible.rate_limit.hit" => :rate_limit_hit,
    "crucible.session.login" => :session_login,
    "crucible.session.logout" => :session_logout
  }

  @doc false
  def handle_telemetry_event(event_name, _measurements, metadata, config) do
    event_type = event_name |> Enum.join(".")
    server = config[:server] || __MODULE__
    atom_event = Map.get(@known_events, event_type, :unknown_event)
    log(server, atom_event, Map.put(metadata, :raw_event, event_type))
  end

  defp default_log_dir do
    repo_root =
      Application.get_env(:crucible, :orchestrator, [])
      |> Keyword.get(:repo_root, File.cwd!())

    Path.join(repo_root, ".claude-flow/logs")
  end
end
