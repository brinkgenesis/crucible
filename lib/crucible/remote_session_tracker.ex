defmodule Crucible.RemoteSessionTracker do
  @moduledoc """
  Tracks a single `claude remote-control` session for the Phoenix Remote tab and API.
  """

  use GenServer
  require Logger

  @name __MODULE__
  @max_lines 500
  @default_permission_mode "bypassPermissions"
  @session_url_regex ~r/https:\/\/claude\.ai\/code\/(?:session_[A-Za-z0-9_-]{20,}|[A-Za-z0-9_-]{20,})/

  @type status :: %{
          running: boolean(),
          url: String.t() | nil,
          pid: integer() | nil,
          startedAt: String.t() | nil,
          cwd: String.t() | nil,
          permissionMode: String.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @spec status() :: status()
  def status do
    with :ok <- ensure_started() do
      safe_genserver_call(:status, default_status())
    else
      _ -> default_status()
    end
  end

  @spec output(non_neg_integer()) :: [String.t()]
  def output(limit \\ 200) do
    with :ok <- ensure_started() do
      safe_genserver_call({:output, max(limit, 0)}, [])
    else
      _ -> []
    end
  end

  @spec start_session(keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(opts \\ []) do
    with :ok <- ensure_started() do
      safe_genserver_call({:start_session, opts}, {:error, :tracker_unavailable})
    else
      _ -> {:error, :tracker_unavailable}
    end
  end

  @spec stop_session() :: map()
  def stop_session do
    with :ok <- ensure_started() do
      safe_genserver_call(:stop_session, %{stopped: false, wasRunning: false})
    else
      _ -> %{stopped: false, wasRunning: false}
    end
  end

  @impl true
  def init(opts) do
    repo_root =
      Keyword.get_lazy(opts, :repo_root, fn ->
        orchestrator_opts = Application.get_env(:crucible, :orchestrator, [])
        Keyword.get(orchestrator_opts, :repo_root, File.cwd!())
      end)

    reap_orphaned_sessions()

    {:ok,
     %{
       repo_root: repo_root,
       cwd: repo_root,
       permission_mode: @default_permission_mode,
       port: nil,
       os_pid: nil,
       started_at: nil,
       url: nil,
       output_lines: [],
       buffer: ""
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {running, state} = ensure_live_state(state)
    {:reply, status_payload(state, running), state}
  end

  def handle_call({:output, limit}, _from, state) do
    {_, state} = ensure_live_state(state)
    {:reply, Enum.take(state.output_lines, -limit), state}
  end

  def handle_call({:start_session, opts}, _from, state) do
    {running, state} = ensure_live_state(state)

    if running do
      {:reply, {:ok, Map.put(status_payload(state, true), :alreadyRunning, true)}, state}
    else
      case System.find_executable("claude") do
        nil ->
          {:reply, {:error, :claude_not_found}, state}

        claude_path ->
          cwd = normalize_cwd(Keyword.get(opts, :cwd), state.repo_root)
          permission_mode = normalize_permission_mode(Keyword.get(opts, :permission_mode))

          args =
            Enum.map(
              ["remote-control", "--permission-mode", permission_mode, "--name", "Infra"],
              &String.to_charlist/1
            )

          port =
            Port.open({:spawn_executable, claude_path}, [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: args,
              cd: String.to_charlist(cwd),
              env:
                Crucible.Secrets.subprocess_env_overrides(
                  keep: Crucible.Secrets.claude_auth_keys()
                )
            ])

          started_at = DateTime.utc_now() |> DateTime.to_iso8601()
          os_pid = port_os_pid(port)

          Logger.info("RemoteSessionTracker: started remote-control session")

          new_state = %{
            state
            | port: port,
              os_pid: os_pid,
              started_at: started_at,
              cwd: cwd,
              permission_mode: permission_mode,
              url: nil,
              output_lines: [],
              buffer: ""
          }

          {:reply, {:ok, Map.put(status_payload(new_state, true), :alreadyRunning, false)},
           new_state}
      end
    end
  rescue
    e ->
      Logger.error("RemoteSessionTracker: start failed: #{Exception.message(e)}")
      {:reply, {:error, :start_failed}, state}
  end

  def handle_call(:stop_session, _from, state) do
    was_running = port_alive?(state.port)
    maybe_close_port(state.port)
    maybe_kill_os_pid(state.os_pid)

    new_state = %{
      state
      | port: nil,
        os_pid: nil,
        started_at: nil,
        cwd: state.repo_root,
        permission_mode: @default_permission_mode,
        url: nil,
        buffer: ""
    }

    {:reply, %{stopped: was_running, wasRunning: was_running}, new_state}
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    raw_text = state.buffer <> to_string(chunk)
    {lines, buffer} = consume_chunk(state.buffer, chunk)
    clean_lines = lines |> Enum.map(&normalize_line/1) |> Enum.reject(&(&1 == ""))

    raw_url_candidate = extract_session_url(raw_text)

    line_url_candidate =
      Enum.find_value(clean_lines, fn line ->
        extract_session_url(line)
      end)

    url =
      better_url(state.url, raw_url_candidate || line_url_candidate)

    output_lines = merge_output_lines(state.output_lines, clean_lines)

    {:noreply, %{state | url: url, output_lines: output_lines, buffer: buffer}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.info("RemoteSessionTracker: remote-control exited with status #{status}")
    {:noreply, %{state | port: nil, os_pid: nil, started_at: nil, url: nil, buffer: ""}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp status_payload(state, running) do
    %{
      running: running,
      url: state.url,
      pid: state.os_pid,
      startedAt: state.started_at,
      cwd: state.cwd,
      permissionMode: state.permission_mode || @default_permission_mode
    }
  end

  defp ensure_live_state(state) do
    running = port_alive?(state.port)

    if running do
      {true, state}
    else
      {false, %{state | port: nil, os_pid: nil, started_at: nil, url: nil, buffer: ""}}
    end
  end

  defp port_alive?(nil), do: false

  defp port_alive?(port) when is_port(port) do
    case Port.info(port) do
      nil -> false
      _ -> true
    end
  rescue
    _ -> false
  end

  defp port_alive?(_), do: false

  defp maybe_close_port(nil), do: :ok

  defp maybe_close_port(port) when is_port(port) do
    if port_alive?(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp maybe_close_port(_), do: :ok

  defp maybe_kill_os_pid(pid) when is_integer(pid) and pid > 0 do
    System.cmd("kill", ["-TERM", Integer.to_string(pid)])
    Process.sleep(200)

    case System.cmd("kill", ["-0", Integer.to_string(pid)]) do
      {_, 0} -> System.cmd("kill", ["-KILL", Integer.to_string(pid)])
      _ -> :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp maybe_kill_os_pid(_), do: :ok

  defp port_os_pid(port) do
    case Port.info(port) do
      info when is_list(info) ->
        case Keyword.get(info, :os_pid) do
          pid when is_integer(pid) and pid > 0 -> pid
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp consume_chunk(buffer, chunk) do
    text = buffer <> to_string(chunk)
    parts = String.split(text, ~r/\r\n|\n|\r/)

    case parts do
      [] ->
        {[], ""}

      [_only] ->
        {[], text}

      _ ->
        lines = Enum.slice(parts, 0, length(parts) - 1)
        tail = List.last(parts) || ""
        {lines, tail}
    end
  end

  defp normalize_line(text) when is_binary(text) do
    text
    |> strip_osc()
    |> strip_ansi()
    |> strip_control_chars()
    |> String.trim()
  end

  defp merge_output_lines(existing, new_lines) do
    {additions, _last_line} =
      Enum.reduce(new_lines, {[], List.last(existing)}, fn line, {adds, last_line} ->
        cond do
          line == last_line ->
            {adds, last_line}

          repeated_recent?(existing, line, 20) ->
            {adds, last_line}

          true ->
            {[line | adds], line}
        end
      end)

    (existing ++ Enum.reverse(additions))
    |> Enum.take(-@max_lines)
  end

  defp repeated_recent?(existing, line, window_size) do
    existing
    |> Enum.take(-window_size)
    |> Enum.any?(&(&1 == line))
  end

  defp strip_ansi(text) when is_binary(text) do
    Regex.replace(~r/\e\[[0-9;?]*[A-Za-z]/, text, "")
  end

  defp strip_osc(text) when is_binary(text) do
    # Removes OSC sequences (including OSC 8 hyperlinks), terminated by BEL or ST.
    Regex.replace(~r/\e\][^\a\x1b]*(?:\a|\e\\)/, text, "")
  end

  defp strip_control_chars(text) when is_binary(text) do
    # Keep visible ASCII/UTF-8 chars; drop remaining control bytes.
    Regex.replace(~r/[\x00-\x1F\x7F]/u, text, "")
  end

  defp better_url(nil, candidate), do: candidate
  defp better_url(existing, nil), do: existing

  defp better_url(existing, candidate) when is_binary(existing) and is_binary(candidate) do
    cond do
      candidate == existing ->
        existing

      String.starts_with?(candidate, existing) and
          String.length(candidate) > String.length(existing) ->
        candidate

      String.length(candidate) > String.length(existing) ->
        candidate

      true ->
        existing
    end
  end

  defp extract_session_url(text) when is_binary(text) do
    cleaned =
      text
      |> strip_osc()
      |> strip_ansi()
      |> strip_control_chars()

    case Regex.run(@session_url_regex, cleaned) do
      [match | _] -> match
      _ -> nil
    end
  end

  defp normalize_cwd(nil, repo_root), do: repo_root

  defp normalize_cwd(cwd, repo_root) when is_binary(cwd) do
    trimmed = String.trim(cwd)
    path = if Path.type(trimmed) == :absolute, do: trimmed, else: Path.expand(trimmed, repo_root)
    if File.dir?(path), do: path, else: repo_root
  end

  defp normalize_cwd(_, repo_root), do: repo_root

  defp normalize_permission_mode("bypassPermissions"), do: "bypassPermissions"
  defp normalize_permission_mode(_), do: @default_permission_mode

  defp safe_genserver_call(message, fallback) do
    GenServer.call(@name, message)
  rescue
    _ -> fallback
  catch
    :exit, _ -> fallback
  end

  defp ensure_started do
    case Process.whereis(@name) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        start_under_aux_supervisor()
    end
  end

  defp start_under_aux_supervisor do
    case Process.whereis(Crucible.AuxSupervisor) do
      pid when is_pid(pid) ->
        spec = %{
          id: @name,
          start: {__MODULE__, :start_link, [[]]},
          restart: :permanent,
          shutdown: 5_000,
          type: :worker
        }

        case Supervisor.start_child(pid, spec) do
          {:ok, _child_pid} ->
            :ok

          {:ok, _child_pid, _info} ->
            :ok

          {:error, {:already_started, _child_pid}} ->
            :ok

          {:error, :already_present} ->
            case Supervisor.restart_child(pid, @name) do
              {:ok, _child_pid} -> :ok
              {:ok, _child_pid, _info} -> :ok
              {:error, {:already_started, _child_pid}} -> :ok
              _ -> start_detached()
            end

          _ ->
            start_detached()
        end

      _ ->
        start_detached()
    end
  rescue
    _ -> start_detached()
  end

  defp start_detached do
    case start_link([]) do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, _reason} = err ->
        err
    end
  rescue
    _ -> {:error, :start_failed}
  end

  defp reap_orphaned_sessions do
    case System.cmd("pgrep", ["-f", "claude.*remote-control"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.each(fn pid_str ->
          case Integer.parse(String.trim(pid_str)) do
            {pid, _} when pid > 0 ->
              Logger.info("RemoteSessionTracker: reaping orphaned process #{pid}")
              maybe_kill_os_pid(pid)

            _ ->
              :ok
          end
        end)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp default_status do
    %{
      running: false,
      url: nil,
      pid: nil,
      startedAt: nil,
      cwd: nil,
      permissionMode: @default_permission_mode
    }
  end
end
