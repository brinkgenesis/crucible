defmodule Crucible.Adapter.SdkPort do
  @moduledoc """
  GenServer managing an Erlang Port to the SDK port bridge (Node.js subprocess).

  Opens a Port to `npx tsx bridge/src/sdk-port-bridge.ts`, sends JSON config on
  stdin, reads newline-delimited JSON events from stdout (tool_use, status,
  result). The bridge ships with Crucible under `bridge/`. Override the path
  with `config :crucible, :sdk_bridge_script, "/abs/path/to/bridge.ts"`.

  OTP guarantees:
  * `terminate/2` always closes the Port and kills the OS process (no zombies)
  * Bounded buffer prevents unbounded memory growth from partial lines
  * Telemetry events at start/complete/error for dashboard observability
  * Caller timeout triggers graceful GenServer stop (triggers terminate/2)

  Lifecycle: start_link(config) → send config → stream events → await result → stop.
  """

  use GenServer
  require Logger

  alias Crucible.Pipeline.OutputProducer

  # 10 MB max buffer for partial lines — prevents OOM from misbehaving subprocess
  @max_buffer_bytes 10_485_760

  @type config :: %{
          prompt: String.t(),
          run_id: String.t(),
          phase_id: String.t(),
          card_id: String.t() | nil,
          infra_home: String.t(),
          phase_type: String.t(),
          phase_name: String.t(),
          routing_profile: String.t() | nil,
          agents: [String.t()],
          timeout_ms: pos_integer(),
          budget_usd: float() | nil,
          max_turns: pos_integer() | nil,
          run: map() | nil,
          phase: map() | nil
        }

  defstruct [
    :port,
    :os_pid,
    :caller,
    :timer_ref,
    :run_id,
    :phase_id,
    :producer_pid,
    :started_at,
    :timeout_ms,
    buffer: "",
    tool_events: [],
    result: nil,
    exited: false,
    ready: false,
    context_usage: nil,
    last_rate_limit: nil,
    session_log_path: nil
  ]

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc "Start the port bridge process."
  def start_link(config, opts \\ []) do
    GenServer.start_link(__MODULE__, config, opts)
  end

  @doc """
  Block until the SDK execution completes and return the result.

  On timeout, stops the GenServer (which triggers terminate/2 to kill the Port).
  """
  @spec await_result(pid(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def await_result(pid, timeout_ms) do
    GenServer.call(pid, :await_result, timeout_ms + 5_000)
  catch
    :exit, {:timeout, _} ->
      # Kill the GenServer (and its Port) — don't leave zombies
      try do
        GenServer.stop(pid, :timeout, 5_000)
      catch
        :exit, _ -> :ok
      end

      {:error, :timeout}
  end

  @doc """
  Send an arbitrary JSON message to the SDK subprocess via stdin.

  The bridge's bidirectional stdin reader parses each line as JSON and
  dispatches by `type` field. Known types: `"interrupt"`, `"message"` (future).
  Fire-and-forget — safe to call even if the port has already exited.

  ## Examples

      SdkPort.send_message(pid, %{type: "interrupt"})
      SdkPort.send_message(pid, %{type: "message", content: "refocus on tests"})
  """
  @spec send_message(pid(), map()) :: :ok | {:error, :missing_type}
  def send_message(pid, %{type: _} = msg) do
    GenServer.cast(pid, {:send_message, msg})
  end

  def send_message(pid, %{"type" => _} = msg) do
    GenServer.cast(pid, {:send_message, msg})
  end

  def send_message(_pid, _msg), do: {:error, :missing_type}

  @doc """
  Send a graceful interrupt to the SDK subprocess via stdin.

  Convenience wrapper around `send_message/2`. The bridge calls
  `stream.interrupt()`, which tells Claude Code to finish its current
  tool and return a partial result.
  """
  @spec send_interrupt(pid()) :: :ok
  def send_interrupt(pid) do
    send_message(pid, %{type: "interrupt"})
  end

  @doc """
  Get the last context usage snapshot (percentage, tokens, max) from the phase.

  Returns `nil` if no context_usage event has been received yet.
  """
  @spec context_usage(pid()) :: map() | nil
  def context_usage(pid) do
    GenServer.call(pid, :context_usage, 5_000)
  catch
    :exit, _ -> nil
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(config) do
    # Trap exits so terminate/2 is called on shutdown
    Process.flag(:trap_exit, true)

    infra_home = Map.fetch!(config, :infra_home)
    bridge_script = bridge_script_path()
    run_id = Map.get(config, :run_id)
    phase_id = Map.get(config, :phase_id)

    port =
      Port.open(
        {:spawn_executable, System.find_executable("npx")},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:line, 1_048_576},
          {:args, ["tsx", bridge_script]},
          {:cd, infra_home},
          {:env, build_port_env()}
        ]
      )

    # Capture OS PID immediately (needed for forceful kill in terminate/2)
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    # Send config as single JSON line on stdin
    json_config = build_start_message(config)
    Port.command(port, json_config <> "\n")

    timeout_ms = Map.get(config, :timeout_ms, 300_000)

    # Boot timeout: if the bridge doesn't send {"type":"ready"} within 30s,
    # something is wrong (Node didn't start, config parse failed, etc.)
    boot_timer_ref = Process.send_after(self(), :boot_timeout, 30_000)

    # Telemetry: port started
    :telemetry.execute(
      [:orchestrator, :sdk_port, :start],
      %{system_time: System.system_time(:millisecond)},
      %{run_id: run_id, phase_id: phase_id, os_pid: os_pid}
    )

    state = %__MODULE__{
      port: port,
      os_pid: os_pid,
      run_id: run_id,
      phase_id: phase_id,
      timer_ref: boot_timer_ref,
      started_at: System.monotonic_time(:millisecond),
      producer_pid: Map.get(config, :producer_pid)
    }

    {:ok, %{state | timeout_ms: timeout_ms}}
  end

  @impl true
  def handle_call(:await_result, from, %{result: nil} = state) do
    {:noreply, %{state | caller: from}}
  end

  def handle_call(:await_result, _from, %{result: result} = state) do
    {:reply, result, state}
  end

  def handle_call(:context_usage, _from, state) do
    {:reply, state.context_usage, state}
  end

  @impl true
  def handle_cast({:send_message, msg}, %{port: port, exited: false} = state)
      when not is_nil(port) do
    msg_type = Map.get(msg, :type) || Map.get(msg, "type") || "unknown"

    Logger.info(
      "SdkPort: sending #{msg_type} for run=#{state.run_id} phase=#{state.phase_id}"
    )

    try do
      Port.command(port, Jason.encode!(msg) <> "\n")
    rescue
      ArgumentError -> :ok
    end

    {:noreply, state}
  end

  def handle_cast({:send_message, _msg}, state), do: {:noreply, state}

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    state = handle_line(line, state)
    {:noreply, state}
  end

  # Partial line — buffer with bounded size check
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    new_buffer = state.buffer <> chunk

    if byte_size(new_buffer) > @max_buffer_bytes do
      Logger.error(
        "SdkPort: buffer overflow (#{byte_size(new_buffer)} bytes) for " <>
          "run=#{state.run_id} phase=#{state.phase_id}"
      )

      emit_error_telemetry(state, :buffer_overflow)
      result = {:error, :buffer_overflow}
      reply_to_caller(state.caller, result)
      {:stop, :normal, %{state | result: result}}
    else
      {:noreply, %{state | buffer: new_buffer}}
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    state = %{state | exited: true}
    cancel_timer(state.timer_ref)

    if state.result == nil do
      Logger.warning("SdkPort: port exited with code #{code} before result")
      emit_error_telemetry(state, {:port_exit, code})
      result = {:error, {:port_exit, code}}
      reply_to_caller(state.caller, result)
      {:stop, :normal, %{state | result: result}}
    else
      {:stop, :normal, state}
    end
  end

  def handle_info(:timeout, state) do
    Logger.warning("SdkPort: timeout for run=#{state.run_id} phase=#{state.phase_id}")
    emit_error_telemetry(state, :timeout)
    close_port(state)
    result = {:error, :timeout}
    reply_to_caller(state.caller, result)
    {:stop, :normal, %{state | result: result, exited: true}}
  end

  def handle_info(:boot_timeout, %{ready: false} = state) do
    Logger.error(
      "SdkPort: bridge did not send 'ready' within 30s for " <>
        "run=#{state.run_id} phase=#{state.phase_id}"
    )

    emit_error_telemetry(state, :boot_timeout)
    close_port(state)
    result = {:error, :boot_timeout}
    reply_to_caller(state.caller, result)
    {:stop, :normal, %{state | result: result, exited: true}}
  end

  # Boot timeout arrived after ready was already received — ignore
  def handle_info(:boot_timeout, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    Logger.info(
      "SdkPort: terminating run=#{state.run_id} phase=#{state.phase_id} reason=#{inspect(reason)}"
    )

    # Close the port gracefully (sends SIGHUP to process group)
    close_port(state)

    # Forceful kill if OS PID is known — belt and suspenders
    if state.os_pid && not state.exited do
      try do
        System.cmd("kill", ["-9", "#{state.os_pid}"], stderr_to_stdout: true)
      rescue
        _ -> :ok
      end
    end

    cancel_timer(state.timer_ref)

    # Notify caller if still waiting
    if state.result == nil do
      reply_to_caller(state.caller, {:error, {:sdk_port_shutdown, reason}})
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Line processing
  # ---------------------------------------------------------------------------

  defp handle_line(line, state) do
    full_line = state.buffer <> line
    state = %{state | buffer: ""}

    case Jason.decode(full_line) do
      {:ok, %{"type" => "ready"}} ->
        handle_ready(state)

      {:ok, %{"type" => "result"} = msg} ->
        handle_result(msg, state)

      {:ok, %{"type" => "tool_use"} = msg} ->
        handle_tool_event(msg, state)

      {:ok, %{"type" => "error"} = msg} ->
        Logger.error("SdkPort: bridge error — #{msg["message"]}")
        state

      {:ok, %{"type" => "agents_configured", "agents" => agents}} ->
        Logger.info("SdkPort: agents configured — #{inspect(agents)}")
        state

      {:ok, %{"type" => "warning", "message" => message}} ->
        Logger.warning("SdkPort: #{message}")
        state

      {:ok, %{"type" => "status"} = msg} ->
        broadcast_status(msg, state)
        state

      {:ok, %{"type" => "api_retry"} = msg} ->
        Logger.warning(
          "SdkPort: API retry #{msg["attempt"]}/#{msg["max_retries"]} " <>
            "(status #{msg["error_status"]}) for run=#{state.run_id}"
        )

        state

      {:ok, %{"type" => "rate_limit"} = msg} ->
        if msg["status"] != "allowed" do
          Logger.warning(
            "SdkPort: rate limit #{msg["status"]} (#{msg["rate_limit_type"]}) " <>
              "utilization=#{msg["utilization"]} for run=#{state.run_id}"
          )
        end

        %{state | last_rate_limit: msg["status"]}

      {:ok, %{"type" => "context_usage"} = msg} ->
        usage = %{
          percentage: msg["percentage"],
          total_tokens: msg["total_tokens"],
          max_tokens: msg["max_tokens"],
          model: msg["model"]
        }

        if msg["percentage"] && msg["percentage"] > 80 do
          Logger.warning(
            "SdkPort: context usage #{msg["percentage"]}% for run=#{state.run_id}"
          )
        end

        %{state | context_usage: usage}

      {:ok, %{"type" => "subagent_event"} = msg} ->
        Logger.info(
          "SdkPort: subagent #{msg["subtype"]} task=#{msg["task_id"]} " <>
            "for run=#{state.run_id}"
        )

        state

      {:ok, %{"type" => "session_log"} = msg} ->
        %{state | session_log_path: msg["path"]}

      {:ok, %{"type" => "cost_event", "payload" => payload}} ->
        Crucible.CostEventWriter.write(payload)
        state

      {:ok, %{"type" => "trace_event", "payload" => payload}} ->
        Crucible.TraceEventWriter.write(state.run_id, payload)
        state

      {:ok, _unknown} ->
        state

      {:error, _} ->
        unless String.trim(full_line) == "" do
          Logger.debug("SdkPort: non-JSON output: #{String.slice(full_line, 0, 200)}")
        end

        state
    end
  end

  defp handle_ready(state) do
    cancel_timer(state.timer_ref)
    timeout_ms = state.timeout_ms || 300_000
    timer_ref = Process.send_after(self(), :timeout, timeout_ms)

    Logger.info(
      "SdkPort: bridge ready for run=#{state.run_id} phase=#{state.phase_id}"
    )

    %{state | ready: true, timer_ref: timer_ref}
  end

  defp handle_result(msg, state) do
    cancel_timer(state.timer_ref)
    duration_ms = System.monotonic_time(:millisecond) - (state.started_at || 0)

    result =
      case msg["subtype"] do
        "success" ->
          {:ok,
           %{
             status: :done,
             cost: msg["cost_usd"],
             model: msg["model"],
             session_id: msg["session_id"],
             attempt_id: msg["attempt_id"],
             turns: msg["turns"],
             input_tokens: msg["input_tokens"] || 0,
             output_tokens: msg["output_tokens"] || 0,
             cache_read_tokens: msg["cache_read_tokens"] || 0,
             tool_call_count: msg["tool_call_count"] || 0,
             files_modified: msg["files_modified"] || [],
             files_created: msg["files_created"] || [],
             context_usage_percent: msg["context_usage_percent"],
             last_rate_limit_status: msg["last_rate_limit_status"],
             session_log_path: msg["session_log_path"] || state.session_log_path
           }}

        "timeout" ->
          {:error, :timeout}

        _ ->
          {:error, {:sdk_error, msg["error"] || msg["subtype"]}}
      end

    # Telemetry: phase complete
    {status_atom, result_data} =
      case result do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, %{error: reason}}
      end

    :telemetry.execute(
      [:orchestrator, :sdk_port, :complete],
      %{
        duration: duration_ms,
        cost: (is_map(result_data) && Map.get(result_data, :cost)) || 0,
        turns: (is_map(result_data) && Map.get(result_data, :turns)) || 0,
        tool_calls: length(state.tool_events)
      },
      %{
        run_id: state.run_id,
        phase_id: state.phase_id,
        status: status_atom,
        subtype: msg["subtype"]
      }
    )

    reply_to_caller(state.caller, result)
    %{state | result: result, caller: nil}
  end

  defp handle_tool_event(msg, state) do
    event = %{
      tool: msg["tool"],
      file_path: msg["file_path"],
      duration_ms: msg["duration_ms"],
      is_error: msg["is_error"] || false,
      was_denied: msg["was_denied"] || false
    }

    if state.producer_pid do
      detail = if event.file_path, do: "#{event.tool} #{event.file_path}", else: event.tool
      OutputProducer.push(state.producer_pid, Jason.encode!(event) <> " | " <> detail)
    end

    %{state | tool_events: [event | state.tool_events]}
  end

  defp broadcast_status(msg, state) do
    if state.producer_pid do
      status_line = "SDK phase: #{msg["message"]} (turn #{msg["turns"]})"
      OutputProducer.push(state.producer_pid, status_line)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp close_port(%{port: port, exited: false}) when not is_nil(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end

  defp close_port(_state), do: :ok

  defp emit_error_telemetry(state, reason) do
    duration_ms = System.monotonic_time(:millisecond) - (state.started_at || 0)

    :telemetry.execute(
      [:orchestrator, :sdk_port, :error],
      %{duration: duration_ms},
      %{run_id: state.run_id, phase_id: state.phase_id, reason: reason}
    )
  end

  defp build_start_message(config) do
    %{
      type: "start",
      prompt: Map.fetch!(config, :prompt),
      runId: Map.get(config, :run_id),
      phaseId: Map.get(config, :phase_id),
      cardId: Map.get(config, :card_id),
      infraHome: Map.fetch!(config, :infra_home),
      repoRoot: Map.get(config, :repo_root) || Map.fetch!(config, :infra_home),
      phaseType: Map.get(config, :phase_type, "session"),
      phaseName: Map.get(config, :phase_name, "unknown"),
      routingProfile: Map.get(config, :routing_profile),
      agents: Map.get(config, :agents, []),
      timeoutMs: Map.get(config, :timeout_ms, 300_000),
      budgetUsd: Map.get(config, :budget_usd),
      maxTurns: Map.get(config, :max_turns),
      resumeSessionId: Map.get(config, :resume_session_id),
      attemptId: Map.get(config, :attempt_id) || generate_attempt_id(),
      run: Map.get(config, :run),
      phase: Map.get(config, :phase)
    }
    |> Jason.encode!()
  end

  defp generate_attempt_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end

  # Resolve the bridge script path. Defaults to `bridge/src/sdk-port-bridge.ts`
  # under the Crucible app's current working directory. Override with
  # `config :crucible, :sdk_bridge_script, "/abs/path/to/bridge.ts"`.
  defp bridge_script_path do
    case Application.get_env(:crucible, :sdk_bridge_script) do
      nil -> Path.join([File.cwd!(), "bridge", "src", "sdk-port-bridge.ts"])
      path when is_binary(path) -> path
    end
  end

  defp build_port_env do
    # Pass through env vars needed by the SDK bridge and its child processes
    needed = ~w(
      PATH HOME NODE_PATH
      ANTHROPIC_API_KEY CLAUDE_PROJECT_DIR
      GITHUB_TOKEN DATABASE_URL
      GOOGLE_API_KEY MINIMAX_API_KEY OPENAI_API_KEY
    )

    for {key, val} <- System.get_env(),
        key in needed,
        do: {String.to_charlist(key), String.to_charlist(val)}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp reply_to_caller(nil, _result), do: :ok
  defp reply_to_caller(caller, result), do: GenServer.reply(caller, result)
end
