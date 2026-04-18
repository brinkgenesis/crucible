defmodule Crucible.Adapter.ClaudeHook do
  @moduledoc """
  File-trigger adapter: pending-pickup pattern for async execution.
  Writes a trigger file and waits for an external Claude Code session to pick it up.
  Used for preflight phases and bridging to interactive sessions.
  """
  @behaviour Crucible.Adapter.Behaviour

  require Logger

  alias Crucible.Claude.Protocol
  alias Crucible.Events

  @claim_poll_ms 200
  @result_poll_ms 1_000
  @pickup_timeout_ms 15 * 60_000

  @impl true
  def execute_phase(run, phase, prompt, opts \\ []) do
    pickup_dir = Keyword.get(opts, :pickup_dir, ".claude-flow/runs/pending-pickup")
    runs_dir = Keyword.get(opts, :runs_dir, ".claude-flow/runs")
    pickup_timeout = Keyword.get(opts, :pickup_timeout_ms, @pickup_timeout_ms)

    File.mkdir_p!(pickup_dir)

    trigger_path = Path.join(pickup_dir, "#{run.id}-#{phase.id}.json")
    team_name = Keyword.get(opts, :team_name)

    # Write trigger file for pickup
    trigger = %{
      runId: run.id,
      phaseIndex: phase.id,
      phaseType: to_string(phase.type),
      teamName: team_name,
      prompt: prompt,
      createdAt: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case Jason.encode(trigger, pretty: true) do
      {:ok, json} ->
        File.write!(trigger_path, json)
        Logger.info("ClaudeHook: wrote trigger to #{trigger_path}")

        # Wait for trigger to be claimed (file disappears)
        case wait_for_claim(trigger_path, pickup_timeout) do
          :ok ->
            Logger.info("ClaudeHook: trigger claimed for run=#{run.id} phase=#{phase.id}")

            # Wait for completion based on phase type
            if phase.type == :team and team_name do
              wait_for_team(team_name, phase.timeout_ms || 600_000)
            else
              sentinel_path = Protocol.sentinel_path(runs_dir, run.id, phase.id)
              wait_for_sentinel(sentinel_path, phase.timeout_ms)
            end

          {:error, :timeout} ->
            Logger.error(
              "ClaudeHook: trigger not picked up within #{pickup_timeout}ms — is a Claude Code session open?"
            )

            File.rm(trigger_path)
            {:error, :pickup_timeout}
        end

      {:error, reason} ->
        {:error, {:encode_failed, reason}}
    end
  end

  @impl true
  def cleanup_artifacts(run, _phase) do
    pickup_dir = ".claude-flow/runs/pending-pickup"

    if File.dir?(pickup_dir) do
      pickup_dir
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, run.id))
      |> Enum.each(fn file ->
        Path.join(pickup_dir, file) |> File.rm()
      end)
    end

    :ok
  end

  # --- Private ---

  defp wait_for_claim(path, timeout, elapsed \\ 0) do
    if elapsed >= timeout do
      {:error, :timeout}
    else
      if File.exists?(path) do
        Process.sleep(@claim_poll_ms)
        wait_for_claim(path, timeout, elapsed + @claim_poll_ms)
      else
        :ok
      end
    end
  end

  defp wait_for_sentinel(path, timeout, elapsed \\ 0) do
    if elapsed >= timeout do
      {:error, :timeout}
    else
      case Protocol.read_sentinel(path) do
        {:ok, sentinel_data} ->
          {:ok, %{status: :completed, sentinel: sentinel_data}}

        _ ->
          Process.sleep(@result_poll_ms)
          wait_for_sentinel(path, timeout, elapsed + @result_poll_ms)
      end
    end
  end

  defp wait_for_team(team_name, timeout) do
    Events.subscribe_team(team_name)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_team_reactive(team_name, deadline)
  end

  defp do_wait_for_team_reactive(team_name, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      snapshot = Protocol.read_team_tasks(team_name)
      config_exists = Protocol.team_config_exists?(team_name)

      cond do
        snapshot.all_completed ->
          {:ok, %{status: :completed, tasks: snapshot}}

        not config_exists and snapshot.total > 0 ->
          Logger.warning(
            "ClaudeHook: team config gone but #{snapshot.total - snapshot.completed}/#{snapshot.total} tasks incomplete"
          )

          {:error, :team_incomplete}

        true ->
          wait_ms = min(remaining, @result_poll_ms)

          receive do
            {:team_completed, ^team_name, _} ->
              snapshot = Protocol.read_team_tasks(team_name)
              {:ok, %{status: :completed, tasks: snapshot}}

            {:team_update, ^team_name, _} ->
              do_wait_for_team_reactive(team_name, deadline)
          after
            wait_ms ->
              do_wait_for_team_reactive(team_name, deadline)
          end
      end
    end
  end
end
