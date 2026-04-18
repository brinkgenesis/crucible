defmodule Crucible.StuckTaskDetector do
  @moduledoc """
  Periodic supervisor for detecting and force-completing stuck tasks.
  Ports the `detectStuckTasks` / `detectIdleStuckTasks` monitoring loop
  from lib/cli/workflow/loop-manager.ts.

  Two detection modes:
    1. Absolute: tasks `in_progress` longer than `stuck_threshold_ms`
    2. Idle-aware: task owner agent idle longer than `idle_threshold_ms`
  """

  use GenServer
  require Logger

  alias Crucible.LoopManager

  @stuck_check_interval_ms 30_000
  @stuck_threshold_ms 10 * 60_000
  @idle_threshold_ms 3 * 60_000

  @type opts :: [
          team_name: String.t(),
          infra_home: String.t(),
          run_id: String.t(),
          phase_id: String.t(),
          stuck_threshold_ms: pos_integer(),
          idle_threshold_ms: pos_integer(),
          check_interval_ms: pos_integer()
        ]

  # --- Client API ---

  @doc "Start monitoring a team phase for stuck tasks."
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Stop the detector."
  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    team_name = Keyword.fetch!(opts, :team_name)
    infra_home = Keyword.get(opts, :infra_home, ".")
    run_id = Keyword.get(opts, :run_id, "unknown")
    phase_id = Keyword.get(opts, :phase_id, "unknown")
    stuck_ms = Keyword.get(opts, :stuck_threshold_ms, @stuck_threshold_ms)
    idle_ms = Keyword.get(opts, :idle_threshold_ms, @idle_threshold_ms)
    interval = Keyword.get(opts, :check_interval_ms, @stuck_check_interval_ms)

    state = %{
      team_name: team_name,
      infra_home: infra_home,
      run_id: run_id,
      phase_id: phase_id,
      stuck_threshold_ms: stuck_ms,
      idle_threshold_ms: idle_ms,
      check_interval_ms: interval,
      force_completed: []
    }

    schedule_check(interval)
    Logger.info("StuckTaskDetector: monitoring team=#{team_name} run=#{run_id} phase=#{phase_id}")
    {:ok, state}
  end

  @impl true
  def handle_info(:check, state) do
    state = run_detection(state)
    schedule_check(state.check_interval_ms)
    {:noreply, state}
  end

  # --- Private ---

  defp schedule_check(interval_ms) do
    Process.send_after(self(), :check, interval_ms)
  end

  defp run_detection(state) do
    # Mode 1: absolute time-based stuck detection
    stuck = LoopManager.detect_stuck_tasks(state.team_name, state.stuck_threshold_ms)
    stuck_ids = MapSet.new(stuck, fn s -> s.file end)

    state =
      Enum.reduce(stuck, state, fn s, acc ->
        Logger.warning(
          "StuckTaskDetector: stuck task #{s.file} (owner: #{get_in(s, [:task, "owner"]) || "unknown"}, stuck #{div(s.stuck_ms, 1000)}s)"
        )

        emit_trace(acc, "stuck_task_detected", %{
          task_file: s.file,
          owner: get_in(s, [:task, "owner"]),
          stuck_duration_ms: s.stuck_ms
        })

        LoopManager.force_complete_task(s.path)
        %{acc | force_completed: [s.file | acc.force_completed]}
      end)

    # Mode 2: idle-aware safety net
    idle_stuck = detect_idle_stuck_tasks(state)

    state =
      idle_stuck
      |> Enum.reject(fn s -> MapSet.member?(stuck_ids, s.file) end)
      |> Enum.reduce(state, fn s, acc ->
        Logger.warning(
          "StuckTaskDetector: idle-stuck task #{s.file} (owner idle #{div(s.idle_ms, 1000)}s)"
        )

        emit_trace(acc, "idle_stuck_detected", %{
          task_file: s.file,
          owner: get_in(s, [:task, "owner"]),
          idle_duration_ms: s.idle_ms
        })

        LoopManager.force_complete_task(s.path)
        %{acc | force_completed: [s.file | acc.force_completed]}
      end)

    # Write wake signal if any tasks were force-completed
    if stuck != [] or idle_stuck != [] do
      write_wake_signal(state)
    end

    state
  end

  defp detect_idle_stuck_tasks(state) do
    task_dir = Path.expand("~/.claude/tasks/#{state.team_name}")

    if File.dir?(task_dir) do
      now = System.system_time(:millisecond)
      idle_times = read_idle_times(state)

      task_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.reduce([], fn file, acc ->
        path = Path.join(task_dir, file)

        with {:ok, content} <- File.read(path),
             {:ok, %{"status" => "in_progress", "owner" => owner} = task}
             when is_binary(owner) <- Jason.decode(content) do
          case Map.get(idle_times, owner) do
            idle_at when is_integer(idle_at) and now - idle_at >= state.idle_threshold_ms ->
              [%{file: file, path: path, task: task, idle_ms: now - idle_at} | acc]

            _ ->
              acc
          end
        else
          _ -> acc
        end
      end)
    else
      []
    end
  rescue
    _ -> []
  end

  defp read_idle_times(state) do
    # Read lifecycle log for idle timestamps per teammate
    log_path = Path.join([state.infra_home, ".claude-flow", "logs", "lifecycle.log"])

    case File.read(log_path) do
      {:ok, content} ->
        # Take last 64KB for efficiency
        content =
          if byte_size(content) > 65_536,
            do: binary_part(content, byte_size(content) - 65_536, 65_536),
            else: content

        content
        |> String.split("\n")
        |> Enum.reduce(%{}, fn line, acc ->
          case Regex.run(~r/\[(\d{4}-\d{2}-\d{2}T[\d:.]+Z?)\].*teammate\s+"([^"]+)".*idle/i, line) do
            [_, ts, name] ->
              case DateTime.from_iso8601(ts) do
                {:ok, dt, _} -> Map.put(acc, name, DateTime.to_unix(dt, :millisecond))
                _ -> acc
              end

            _ ->
              acc
          end
        end)

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp write_wake_signal(state) do
    signals_dir = Path.join(state.infra_home, ".claude-flow/signals")
    File.mkdir_p!(signals_dir)
    signal_path = Path.join(signals_dir, "#{state.team_name}.wake")
    File.write!(signal_path, DateTime.utc_now() |> DateTime.to_iso8601())
  rescue
    _ -> :ok
  end

  defp emit_trace(state, event_type, metadata) do
    event = %{
      eventType: event_type,
      runId: state.run_id,
      phaseId: state.phase_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      metadata: metadata
    }

    Phoenix.PubSub.broadcast(
      Crucible.PubSub,
      "orchestrator:traces",
      {:trace_event, event}
    )
  rescue
    _ -> :ok
  end
end
