defmodule Crucible.Claude.Session do
  @moduledoc """
  Tmux-based Claude CLI session management.

  Matches the TypeScript predecessor's approach:
  1. Creates a detached tmux session
  2. Spawns `claude --permission-mode bypassPermissions` interactively
  3. Waits for the Claude TUI to be ready (❯ prompt)
  4. Injects prompt via tmux paste buffer (bracketed paste)
  5. Polls for sentinel file completion
  6. Captures final pane output and kills session
  """

  require Logger

  alias Crucible.Claude.{OutputParser, Protocol}

  @ready_timeout_ms 90_000
  @ready_poll_ms 2_000
  @sentinel_poll_ms 3_000
  @inject_settle_ms 1_500
  # Minimum runtime before idle detection kicks in (prevents premature completion)
  @min_runtime_session_ms 120_000
  @min_runtime_team_ms 600_000
  # Consecutive idle polls required before triggering completion
  @idle_polls_required 3

  @pubsub Crucible.PubSub

  @type session_opts :: [
          budget: float(),
          timeout_ms: pos_integer(),
          permission_mode: String.t(),
          resume_session_id: String.t() | nil,
          run_id: String.t(),
          phase_id: String.t(),
          runs_dir: String.t(),
          is_team: boolean(),
          pipeline: boolean()
        ]

  @type session_result :: %{
          output: String.t(),
          exit_status: integer(),
          cost: float() | nil,
          tokens: map(),
          session_url: String.t() | nil,
          session_id: String.t() | nil,
          elapsed_ms: integer()
        }

  @doc """
  Spawns an interactive Claude session in a tmux pane, injects the prompt,
  and blocks until the sentinel file appears (phase completion).
  """
  @spec execute(String.t(), String.t(), session_opts()) ::
          {:ok, session_result()} | {:error, term()}
  def execute(prompt, working_dir, opts \\ []) do
    run_id = Keyword.get(opts, :run_id, "unknown")
    phase_id = Keyword.get(opts, :phase_id, "p0")
    timeout = Keyword.get(opts, :timeout_ms, 600_000)
    is_team = Keyword.get(opts, :is_team, false)
    pipeline = Keyword.get(opts, :pipeline, false)

    session_name = build_session_name(run_id, phase_id)
    started_at = System.monotonic_time(:millisecond)

    Logger.info("Claude.Session: creating tmux session #{session_name} in #{working_dir}")

    with :ok <- create_tmux_session(session_name, working_dir, opts),
         :ok <- wait_for_ready(session_name, run_id),
         :ok <- maybe_start_pipeline(pipeline, session_name, run_id, phase_id),
         :ok <- inject_prompt(session_name, prompt),
         {:ok, output} <-
           wait_for_completion(session_name, run_id, phase_id, timeout, started_at, is_team, opts) do
      elapsed = System.monotonic_time(:millisecond) - started_at

      if pipeline, do: maybe_stop_pipeline(session_name)

      persist_session_log(run_id, phase_id, output, working_dir)

      {:ok,
       %{
         output: output,
         exit_status: 0,
         cost: OutputParser.extract_cost(output),
         tokens: OutputParser.extract_tokens(output),
         session_url: OutputParser.extract_session_url(output),
         session_id: OutputParser.extract_session_id(output),
         elapsed_ms: elapsed
       }}
    else
      {:error, reason} = err ->
        Logger.error("Claude.Session: #{session_name} failed: #{inspect(reason)}")

        if pipeline, do: maybe_stop_pipeline(session_name)

        kill_session(session_name)
        err
    end
  end

  @doc """
  Returns the PubSub topic for pipeline feedback signals.
  Consumers broadcast to this topic; Session listens on it.
  """
  @spec pipeline_topic(String.t(), String.t()) :: String.t()
  def pipeline_topic(run_id, phase_id), do: "pipeline:#{run_id}:#{phase_id}"

  @doc """
  Query current pipeline stats for a session (cost tracking + drift state).
  Returns `{:ok, stats}` if the pipeline is running, `:not_running` otherwise.
  """
  @spec pipeline_stats(String.t()) :: {:ok, map()} | :not_running
  def pipeline_stats(session_name) do
    supervisor = Module.concat(Crucible.Pipeline, PipelineSupervisor)

    if Code.ensure_loaded?(supervisor) and function_exported?(supervisor, :running?, 1) and
         supervisor.running?(session_name) do
      cost_name = supervisor.cost_consumer_name(session_name)
      drift_name = supervisor.drift_consumer_name(session_name)

      cost_mod = Module.concat(Crucible.Pipeline, CostConsumer)
      drift_mod = Module.concat(Crucible.Pipeline, DriftConsumer)

      cost_stats =
        if Code.ensure_loaded?(cost_mod) and function_exported?(cost_mod, :get_stats, 1) do
          try do
            cost_mod.get_stats(cost_name)
          catch
            :exit, _ -> %{}
          end
        else
          %{}
        end

      drift_stats =
        if Code.ensure_loaded?(drift_mod) and function_exported?(drift_mod, :get_state, 1) do
          try do
            drift_mod.get_state(drift_name)
          catch
            :exit, _ -> %{}
          end
        else
          %{}
        end

      {:ok, %{cost: cost_stats, drift: drift_stats}}
    else
      :not_running
    end
  end

  # --- Pipeline integration ---

  defp maybe_start_pipeline(false, _session_name, _run_id, _phase_id), do: :ok

  defp maybe_start_pipeline(true, session_name, run_id, phase_id) do
    # Subscribe to the topics consumers actually broadcast on
    Phoenix.PubSub.subscribe(@pubsub, "pipeline:control")
    Phoenix.PubSub.subscribe(@pubsub, "pipeline:costs")
    Phoenix.PubSub.subscribe(@pubsub, "pipeline:drift")

    Logger.info(
      "Claude.Session: subscribed to pipeline feedback for #{session_name} " <>
        "(run=#{run_id}, phase=#{phase_id})"
    )

    supervisor = Module.concat(Crucible.Pipeline, PipelineSupervisor)

    if Code.ensure_loaded?(supervisor) and function_exported?(supervisor, :start_pipeline, 1) do
      case supervisor.start_pipeline(
             session_name: session_name,
             run_id: run_id,
             phase_id: phase_id
           ) do
        {:ok, _pid} ->
          Logger.info("Claude.Session: pipeline started for #{session_name}")
          :ok

        {:error, reason} ->
          Logger.error("Claude.Session: pipeline start failed: #{inspect(reason)}")
          {:error, {:pipeline_start_failed, reason}}
      end
    else
      Logger.warning(
        "Claude.Session: PipelineSupervisor not available, running without pipeline analysis"
      )

      :ok
    end
  end

  @doc false
  def drain_pipeline_signals(session_name) do
    receive do
      # Budget exceeded signal from CostConsumer
      %{event: :budget_exceeded, run_id: run_id, phase_id: phase_id} = details ->
        Logger.warning(
          "Claude.Session: pipeline budget exceeded " <>
            "(run=#{run_id}, phase=#{phase_id}, cost=$#{details[:total_cost]})"
        )

        {:terminate, :budget_exceeded}

      # Drift termination signal from DriftConsumer
      %{event: :drift_termination, run_id: run_id, phase_id: phase_id, reason: reason} ->
        Logger.warning(
          "Claude.Session: pipeline drift termination " <>
            "(run=#{run_id}, phase=#{phase_id}, reason=#{reason})"
        )

        {:terminate, {:drift, reason}}

      # Drift alert (non-terminal) — log and continue
      %{event: :drift_alert, run_id: run_id, phase_id: phase_id, type: type, message: msg} ->
        Logger.warning(
          "Claude.Session: pipeline drift alert #{type} " <>
            "(run=#{run_id}, phase=#{phase_id}): #{msg}"
        )

        :continue

      # Cost update (informational) — ignore in drain
      %{event: :cost_update} ->
        :continue

      # Legacy tuple-based signals (backward compat)
      {:pipeline_terminate_phase, run_id, phase_id, reason} ->
        Logger.warning(
          "Claude.Session: pipeline requested phase termination " <>
            "(run=#{run_id}, phase=#{phase_id}, reason=#{reason})"
        )

        {:terminate, reason}

      {:pipeline_budget_exceeded, run_id, phase_id, details} ->
        Logger.warning(
          "Claude.Session: pipeline budget exceeded " <>
            "(run=#{run_id}, phase=#{phase_id}, details=#{inspect(details)})"
        )

        {:terminate, :budget_exceeded}

      {:pipeline_inject_prompt, _run_id, _phase_id, prompt_text} ->
        inject_prompt(session_name, prompt_text)
        :continue
    after
      0 -> :none
    end
  end

  @doc false
  defp maybe_forward_to_pipeline(content, session_name) do
    producer_mod = Module.concat(Crucible.Pipeline, OutputProducer)
    supervisor_mod = Module.concat(Crucible.Pipeline, PipelineSupervisor)

    if Code.ensure_loaded?(producer_mod) and function_exported?(producer_mod, :push, 2) and
         Code.ensure_loaded?(supervisor_mod) and
         function_exported?(supervisor_mod, :producer_name, 1) do
      producer_name = supervisor_mod.producer_name(session_name)
      producer_mod.push(producer_name, content)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp maybe_stop_pipeline(session_name) do
    supervisor = Module.concat(Crucible.Pipeline, PipelineSupervisor)

    if Code.ensure_loaded?(supervisor) and function_exported?(supervisor, :stop_pipeline, 1) do
      case supervisor.stop_pipeline(session_name) do
        :ok ->
          Logger.info("Claude.Session: pipeline stopped for #{session_name}")

        {:error, reason} ->
          Logger.warning(
            "Claude.Session: pipeline stop failed for #{session_name}: #{inspect(reason)}"
          )
      end
    end

    # Unsubscribe from pipeline PubSub topics
    Phoenix.PubSub.unsubscribe(@pubsub, "pipeline:control")
    Phoenix.PubSub.unsubscribe(@pubsub, "pipeline:costs")
    Phoenix.PubSub.unsubscribe(@pubsub, "pipeline:drift")

    :ok
  rescue
    _ -> :ok
  end

  # --- Tmux primitives ---

  @doc false
  def tmux(args, opts \\ []) do
    ignore_error = Keyword.get(opts, :ignore_error, false)

    case System.cmd("tmux", String.split(args), stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {err, _code} ->
        if ignore_error, do: {:ok, ""}, else: {:error, err}
    end
  end

  defp session_exists?(name) do
    case System.cmd("tmux", ["has-session", "-t", name], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp capture_pane(target) do
    case System.cmd("tmux", ["capture-pane", "-p", "-S", "-500", "-t", target],
           stderr_to_stdout: true
         ) do
      {output, 0} -> output
      _ -> ""
    end
  end

  # --- Session lifecycle ---

  defp create_tmux_session(session_name, working_dir, opts) do
    is_team = Keyword.get(opts, :is_team, false)
    run_id = Keyword.get(opts, :run_id, "")
    client_id = Keyword.get(opts, :client_id, "")

    # Kill stale session with same name
    if session_exists?(session_name) do
      tmux("kill-session -t #{session_name}", ignore_error: true)
      Process.sleep(500)
    end

    # Create detached tmux session with large window
    case System.cmd(
           "tmux",
           [
             "new-session",
             "-d",
             "-s",
             session_name,
             "-c",
             working_dir,
             "-x",
             "200",
             "-y",
             "50"
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        # Set large scrollback buffer for capturing output
        System.cmd("tmux", ["set-option", "-t", session_name, "history-limit", "5000"],
          stderr_to_stdout: true
        )

        :ok

      {err, _} ->
        {:error, {:tmux_create_failed, err}}
    end
    |> case do
      :ok ->
        # Build the claude launch command with env vars
        teams_flag = if is_team, do: "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 ", else: ""
        run_id_flag = if run_id != "", do: "INFRA_RUN_ID=#{run_id} ", else: ""
        client_id_flag = if client_id != "", do: "INFRA_CLIENT_ID=#{client_id} ", else: ""
        env_prefix = Crucible.Secrets.shell_env_prefix(keep: Crucible.Secrets.claude_auth_keys())

        cmd =
          [
            env_prefix,
            "CLAUDECODE= #{teams_flag}#{run_id_flag}#{client_id_flag}claude --permission-mode bypassPermissions"
          ]
          |> Enum.reject(&(&1 == ""))
          |> Enum.join(" ")

        # Send the command to start Claude
        case System.cmd("tmux", ["send-keys", "-t", session_name, cmd, "Enter"],
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            Logger.info("Claude.Session: spawned Claude in tmux session #{session_name}")
            :ok

          {err, _} ->
            {:error, {:tmux_send_failed, err}}
        end

      err ->
        err
    end
  end

  defp kill_session(session_name) do
    tmux("kill-session -t #{session_name}", ignore_error: true)
    Logger.info("Claude.Session: killed tmux session #{session_name}")
  end

  # --- Ready detection ---

  defp wait_for_ready(session_name, run_id) do
    deadline = System.monotonic_time(:millisecond) + @ready_timeout_ms
    Logger.info("Claude.Session: waiting for Claude to be ready in #{session_name}")
    do_wait_for_ready(session_name, run_id, deadline)
  end

  defp do_wait_for_ready(session_name, run_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Logger.error(
        "Claude.Session: Claude failed to start in #{session_name} within #{@ready_timeout_ms}ms"
      )

      {:error, :startup_timeout}
    else
      Process.sleep(@ready_poll_ms)

      if not session_exists?(session_name) do
        {:error, :session_died}
      else
        content = capture_pane(session_name)

        if claude_ready?(content) do
          startup_ms = @ready_timeout_ms - remaining + @ready_poll_ms
          Logger.info("Claude.Session: ready in #{session_name} (#{startup_ms}ms)")
          :ok
        else
          do_wait_for_ready(session_name, run_id, deadline)
        end
      end
    end
  end

  @doc """
  Multi-signal Claude readiness detection. Requires BOTH:
  1. Prompt character (❯ or >) near the bottom of the pane
  2. Corroborating TUI signals (cost display, mode indicator, etc.)
  """
  def claude_ready?(pane_content) do
    lines = String.split(pane_content, "\n")
    non_empty = Enum.filter(lines, &(String.trim(&1) != ""))

    if non_empty == [] do
      false
    else
      # Signal 1: prompt character in last 5 non-empty lines
      tail = Enum.slice(non_empty, -5..-1//1)

      has_prompt =
        Enum.any?(tail, fn line ->
          trimmed = String.trim(line)
          # ❯ at start (main prompt, not @teammate❯)
          # bare > prompt
          (String.starts_with?(trimmed, "❯") and not String.starts_with?(trimmed, "@")) or
            trimmed == ">" or
            Regex.match?(~r/^>\s*$/, trimmed)
        end)

      if not has_prompt do
        false
      else
        # Signal 2: corroborating TUI indicators
        full = pane_content

        Regex.match?(~r/\$\d+\.\d{2}/, full) or
          Regex.match?(~r/\d+\.?\d*k?\s*tokens/i, full) or
          Regex.match?(~r/bypassPermissions|planMode|acceptEdits/i, full) or
          Regex.match?(~r/claude\s*(code)?/i, full) or
          Regex.match?(~r/\/help|\/clear|\/compact/i, full) or
          Regex.match?(~r/esc\s+to\s+(cancel|undo|close)/i, full)
      end
    end
  end

  # --- Prompt injection ---

  defp inject_prompt(session_name, prompt) do
    # Write prompt to temp file
    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "wf-prompt-#{:crypto.strong_rand_bytes(4) |> Base.hex_encode32(case: :lower, padding: false)}.txt"
      )

    # Use a per-session buffer name to prevent concurrent sessions from overwriting
    # each other's prompts (all 3 concurrent runs were sharing "wf-inject" buffer)
    buffer_name = "wf-#{session_name}"

    try do
      File.write!(tmp_path, prompt)

      # Load into tmux named buffer (scoped per session)
      case System.cmd("tmux", ["load-buffer", "-b", buffer_name, tmp_path],
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {err, _} -> throw({:load_buffer_failed, err})
      end

      # Paste using bracketed paste (-p flag)
      case System.cmd("tmux", ["paste-buffer", "-p", "-b", buffer_name, "-t", session_name],
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {err, _} -> throw({:paste_buffer_failed, err})
      end

      # Wait for Ink TUI to process
      Process.sleep(@inject_settle_ms)

      # Submit with Enter
      case System.cmd("tmux", ["send-keys", "-t", session_name, "Enter"], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {err, _} -> throw({:send_enter_failed, err})
      end

      Logger.info(
        "Claude.Session: injected prompt (#{byte_size(prompt)} bytes) into #{session_name}"
      )

      :ok
    catch
      {:load_buffer_failed, err} -> {:error, {:inject_failed, err}}
      {:paste_buffer_failed, err} -> {:error, {:inject_failed, err}}
      {:send_enter_failed, err} -> {:error, {:inject_failed, err}}
    after
      File.rm(tmp_path)
    end
  end

  # --- Completion detection (FileSystem watcher + polling fallback) ---

  defp wait_for_completion(session_name, run_id, phase_id, timeout, started_at, is_team, opts) do
    runs_dir = Keyword.get(opts, :runs_dir, ".claude-flow/runs")
    sentinel_path = Protocol.sentinel_path(runs_dir, run_id, phase_id)
    deadline = started_at + timeout
    sentinel_dir = Path.dirname(sentinel_path)
    _sentinel_name = Path.basename(sentinel_path)

    # Start filesystem watcher on the sentinel directory
    File.mkdir_p!(sentinel_dir)
    watcher_pid = start_sentinel_watcher(sentinel_dir)

    Logger.info(
      "Claude.Session: watching for completion (sentinel=#{sentinel_path}, watcher=#{inspect(watcher_pid)})"
    )

    try do
      if is_team do
        workflow_type = Keyword.get(opts, :workflow_type, "unknown")
        phase_index = Keyword.get(opts, :phase_index, 0)
        team_name = "#{workflow_type}-#{String.slice(run_id, 0, 8)}-#{phase_index}"

        do_wait_for_completion_team(
          session_name,
          sentinel_path,
          team_name,
          deadline,
          started_at,
          _idle_count = 0
        )
      else
        do_wait_for_completion_session(
          session_name,
          sentinel_path,
          deadline,
          _reminder_sent = false,
          started_at,
          _idle_count = 0
        )
      end
    after
      stop_sentinel_watcher(watcher_pid)
    end
  end

  defp start_sentinel_watcher(dir) do
    case FileSystem.start_link(dirs: [dir]) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        pid

      {:error, reason} ->
        Logger.warning(
          "Claude.Session: FileSystem watcher failed (#{inspect(reason)}), using polling fallback"
        )

        nil
    end
  end

  # Waits for a filesystem event (instant wake) or falls back to timeout (polling interval).
  # Drains any queued FS events so they don't accumulate across loops.
  defp wait_for_fs_event_or_timeout(timeout_ms) do
    receive do
      {:file_event, _pid, {_path, _events}} -> :ok
      {:file_event, _pid, :stop} -> :ok
    after
      timeout_ms -> :ok
    end

    # Drain any additional queued events
    drain_fs_events()
  end

  defp drain_fs_events do
    receive do
      {:file_event, _pid, _} -> drain_fs_events()
    after
      0 -> :ok
    end
  end

  defp stop_sentinel_watcher(nil), do: :ok

  defp stop_sentinel_watcher(pid) do
    GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _ -> :ok
  end

  defp do_wait_for_completion_session(
         session_name,
         sentinel_path,
         deadline,
         reminder_sent,
         started_at,
         idle_count
       ) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      # Wait for FileSystem event or fall back to polling interval
      wait_for_fs_event_or_timeout(min(@sentinel_poll_ms, remaining))

      # Check for pipeline feedback signals (terminate/inject)
      case drain_pipeline_signals(session_name) do
        {:terminate, reason} ->
          output = capture_pane(session_name)
          kill_session(session_name)
          {:ok, "[pipeline:terminated:#{reason}]\n" <> output}

        _ ->
          :ok
      end
      |> case do
        {:ok, _} = result ->
          result

        :ok ->
          cond do
            File.exists?(sentinel_path) ->
              output = capture_pane(session_name)
              kill_session(session_name)
              {:ok, output}

            not session_exists?(session_name) ->
              if File.exists?(sentinel_path) do
                {:ok, ""}
              else
                {:error, :session_exited}
              end

            true ->
              content = capture_pane(session_name)
              maybe_forward_to_pipeline(content, session_name)
              elapsed = System.monotonic_time(:millisecond) - started_at
              past_min_runtime = elapsed >= @min_runtime_session_ms

              is_idle =
                past_min_runtime and claude_ready?(content) and phase_output_detected?(content)

              new_idle_count = if is_idle, do: idle_count + 1, else: 0

              cond do
                new_idle_count < @idle_polls_required ->
                  do_wait_for_completion_session(
                    session_name,
                    sentinel_path,
                    deadline,
                    reminder_sent,
                    started_at,
                    new_idle_count
                  )

                not reminder_sent ->
                  Logger.warning(
                    "Claude.Session: Claude idle for #{new_idle_count} polls (#{div(elapsed, 1000)}s elapsed), injecting reminder"
                  )

                  inject_sentinel_reminder(session_name, sentinel_path)

                  do_wait_for_completion_session(
                    session_name,
                    sentinel_path,
                    deadline,
                    true,
                    started_at,
                    0
                  )

                true ->
                  Process.sleep(2_000)

                  if File.exists?(sentinel_path) do
                    Logger.info("Claude.Session: sentinel appeared after brief wait")
                    output = capture_pane(session_name)
                    kill_session(session_name)
                    {:ok, output}
                  else
                    Logger.warning(
                      "Claude.Session: no sentinel after reminder, capturing output as fallback"
                    )

                    kill_session(session_name)
                    {:ok, content}
                  end
              end
          end
      end
    end
  end

  defp do_wait_for_completion_team(
         session_name,
         sentinel_path,
         team_name,
         deadline,
         started_at,
         idle_count
       ) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      # Wait for FileSystem event or fall back to polling interval
      wait_for_fs_event_or_timeout(min(@sentinel_poll_ms, remaining))

      # Check for pipeline feedback signals (terminate/inject)
      case drain_pipeline_signals(session_name) do
        {:terminate, reason} ->
          output = capture_pane(session_name)
          kill_session(session_name)
          {:ok, "[pipeline:terminated:#{reason}]\n" <> output}

        _ ->
          :ok
      end
      |> case do
        {:ok, _} = result ->
          result

        :ok ->
          cond do
            File.exists?(sentinel_path) ->
              output = capture_pane(session_name)
              kill_session(session_name)
              {:ok, output}

            not session_exists?(session_name) ->
              if File.exists?(sentinel_path) do
                {:ok, ""}
              else
                {:error, :session_exited}
              end

            true ->
              content = capture_pane(session_name)
              maybe_forward_to_pipeline(content, session_name)
              task_snapshot = Protocol.read_team_tasks(team_name)
              elapsed = System.monotonic_time(:millisecond) - started_at
              past_min_runtime = elapsed >= @min_runtime_team_ms

              is_idle =
                past_min_runtime and claude_ready?(content) and phase_output_detected?(content) and
                  not task_snapshot.exists

              new_idle_count = if is_idle, do: idle_count + 1, else: 0

              cond do
                task_snapshot.all_completed ->
                  Logger.info("Claude.Session: all team tasks completed for #{team_name}")
                  kill_session(session_name)
                  {:ok, content}

                new_idle_count >= @idle_polls_required ->
                  Logger.warning(
                    "Claude.Session: agent idle for #{new_idle_count} polls (#{div(elapsed, 1000)}s), no team for #{team_name} — treating as complete"
                  )

                  kill_session(session_name)
                  {:ok, content}

                true ->
                  do_wait_for_completion_team(
                    session_name,
                    sentinel_path,
                    team_name,
                    deadline,
                    started_at,
                    new_idle_count
                  )
              end
          end
      end
    end
  end

  # Heuristic: Claude produced meaningful output beyond the injected prompt
  defp phase_output_detected?(content) do
    lines = String.split(content, "\n") |> Enum.filter(&(String.trim(&1) != ""))

    # Must have substantial content AND evidence of actual work (tool usage or completion markers)
    length(lines) > 10 and agent_did_work?(content)
  end

  # Check for evidence that the agent actually completed work, not just started it
  defp agent_did_work?(content) do
    # Completed tool output markers (⎿ = tool result, "Worked for" = session done)
    # File operations that completed (Write/Edit with file paths in results)
    # Test/compile results
    # Git operations that ran
    Regex.match?(~r/Worked for \d|Done \(\d+ tool|⎿\s+\S/u, content) or
      Regex.match?(~r/✓\s+|✗\s+|file[s]? changed|insertions?\(\+\)/u, content) or
      Regex.match?(~r/\d+ tests?,?\s+\d+\s+failure|Generated \w+ app/i, content) or
      Regex.match?(~r/\[[\w-]+\s+[a-f0-9]+\]|On branch \w+/i, content)
  end

  # Send a follow-up prompt reminding Claude to write the sentinel file
  defp inject_sentinel_reminder(session_name, sentinel_path) do
    reminder =
      "You forgot to write the sentinel file. Please write it now:\necho '{\"status\":\"done\",\"commitHash\":\"'$(git rev-parse HEAD)'\"}' > #{sentinel_path}"

    inject_prompt(session_name, reminder)
  end

  # --- Session log persistence ---

  @session_logs_rel ".claude-flow/logs/sessions"

  defp persist_session_log(run_id, phase_id, output, working_dir) when is_binary(output) do
    dir = Path.join(working_dir, @session_logs_rel)
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{run_id}-#{phase_id}.log")
    File.write(path, OutputParser.strip_ansi(output))
  rescue
    _ -> :ok
  end

  defp persist_session_log(_, _, _, _), do: :ok

  # --- Helpers ---

  defp build_session_name(run_id, phase_id) do
    # Tmux session names can't have dots or colons
    clean_run = String.replace(run_id, ~r/[^a-zA-Z0-9_-]/, "")
    clean_phase = String.replace(phase_id, ~r/[^a-zA-Z0-9_-]/, "")
    "orch-#{clean_run}-#{clean_phase}"
  end

  @doc """
  Returns env overrides for Claude subprocess.

  Port.open's `env:` option EXTENDS the parent environment (not replaces it).
  To unset a var, we set it to `false` (Erlang convention).
  We only pass the deltas: vars to unset or override.
  """
  @spec clean_env() :: [{charlist(), charlist() | false}]
  def clean_env do
    Crucible.Secrets.subprocess_env_overrides(keep: Crucible.Secrets.claude_auth_keys())
  end
end
