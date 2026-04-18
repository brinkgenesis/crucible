defmodule Crucible.PhaseRunner.Detectors do
  @moduledoc """
  Manages runtime anomaly detectors that run alongside long-lived phase
  executions:

  * **Loop detector** — fires a periodic timer; `handle_loop_check/2` is called
    by the owning process when the message arrives.
  * **Stuck-task detector** — only for `:team` phases; supervises agent task
    progress and emits warnings.
  """

  require Logger

  alias Crucible.Types.{Run, Phase}
  alias Crucible.{LoopDetector, StuckTaskDetector}

  @loop_check_interval_ms 30_000
  @trace_rel ".claude-flow/logs/traces"

  @doc """
  Start a loop-check timer for the calling process.
  Returns `nil` for phases that don't need it (`:preflight`, `:review_gate`).
  """
  @spec maybe_start_loop_detector(Run.t(), Phase.t()) :: reference() | nil
  def maybe_start_loop_detector(_run, %Phase{type: type})
      when type in [:preflight, :review_gate],
      do: nil

  def maybe_start_loop_detector(run, phase) do
    Process.send_after(self(), {:loop_check, run.id, phase.id}, @loop_check_interval_ms)
  end

  @doc """
  Start a StuckTaskDetector for `:team` phases.
  Returns `nil` for all other phase types.
  """
  @spec maybe_start_stuck_detector(Run.t(), Phase.t(), String.t()) :: pid() | nil
  def maybe_start_stuck_detector(_run, %Phase{type: type}, _infra_home)
      when type != :team,
      do: nil

  def maybe_start_stuck_detector(run, phase, infra_home) do
    team_name = "#{run.workflow_type}-#{String.slice(run.id, 0, 8)}-#{phase.phase_index}"

    case StuckTaskDetector.start_link(
           team_name: team_name,
           infra_home: infra_home,
           run_id: run.id,
           phase_id: phase.id
         ) do
      {:ok, pid} -> pid
      _ -> nil
    end
  end

  @doc """
  Inspect recent trace events for the given run and report any detected loops.
  Returns `:ok` or `{:halt, report}`.
  """
  @spec handle_loop_check(String.t(), String.t()) :: :ok | {:halt, map()}
  def handle_loop_check(run_id, phase_id) do
    Logger.debug("PhaseRunner: loop check for run=#{run_id} phase=#{phase_id}")

    traces_dir = resolve_path(@trace_rel)

    edit_events =
      read_recent_trace_events(traces_dir, run_id, "tool_call")
      |> Enum.filter(&(Map.get(&1, "tool") == "edit"))
      |> Enum.map(fn e ->
        %{file: get_in(e, ["metadata", "file"]) || "", timestamp: Map.get(e, "timestamp", "")}
      end)

    command_events =
      read_recent_trace_events(traces_dir, run_id, "tool_call")
      |> Enum.filter(&(Map.get(&1, "tool") == "bash"))
      |> Enum.map(fn e ->
        %{
          command: get_in(e, ["metadata", "command"]) || "",
          exit_code: get_in(e, ["metadata", "exitCode"]) || 0
        }
      end)

    reports =
      LoopDetector.run_all(%{
        edit_events: edit_events,
        command_events: command_events
      })

    case Enum.find(reports, &(&1.severity == :error)) do
      nil ->
        if reports != [],
          do:
            Logger.warning(
              "PhaseRunner: loop warnings for #{run_id}/#{phase_id}: #{inspect(reports)}"
            )

        :ok

      report ->
        Logger.error("PhaseRunner: loop detected for #{run_id}/#{phase_id}: #{report.suggestion}")

        {:halt, report}
    end
  end

  # --- Private ---

  defp read_recent_trace_events(traces_dir, run_id, event_type) do
    if File.dir?(traces_dir) do
      traces_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
      |> Enum.flat_map(fn file ->
        Path.join(traces_dir, file)
        |> File.stream!()
        |> Stream.map(&Jason.decode/1)
        |> Stream.filter(fn
          {:ok, %{"runId" => ^run_id, "eventType" => ^event_type}} -> true
          _ -> false
        end)
        |> Stream.map(fn {:ok, event} -> event end)
        |> Enum.to_list()
      end)
    else
      []
    end
  rescue
    e ->
      Logger.warning("PhaseRunner: read_recent_trace_events failed: #{Exception.message(e)}")
      []
  end

  defp resolve_path(rel) do
    config = Application.get_env(:crucible, :orchestrator, [])
    repo_root = Keyword.get(config, :repo_root, File.cwd!())
    Path.join(repo_root, rel)
  end
end
