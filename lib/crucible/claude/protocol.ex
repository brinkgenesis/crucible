defmodule Crucible.Claude.Protocol do
  @moduledoc """
  Sentinel file protocol for phase completion signals.
  Handles reading, writing, and validating `.done` sentinel files
  used to coordinate phase completion between adapters and the orchestrator.
  """

  require Logger

  alias Crucible.Events

  @type sentinel_result :: %{
          status: String.t(),
          commit_hash: String.t() | nil,
          no_changes: boolean(),
          execution_type: String.t() | nil
        }

  @doc """
  Returns the sentinel file path for a given run/phase.
  Format: `<runs_dir>/<run_id>-p<phase_index>.done`

  Handles both formats of phase_id:
  - Already prefixed: "run123-p0" → strips the run_id prefix to avoid duplication
  - Index only: "p0" or "0" → prepended with run_id
  """
  @spec sentinel_path(String.t(), String.t(), String.t() | nil) :: String.t()
  def sentinel_path(runs_dir, run_id, phase_id) do
    suffix =
      cond do
        # phase_id already starts with run_id prefix — extract just the pN part
        is_binary(phase_id) and String.starts_with?(phase_id, run_id <> "-") ->
          String.replace_prefix(phase_id, run_id <> "-", "")

        # phase_id is just the pN or index
        true ->
          phase_id
      end

    Path.join(runs_dir, "#{run_id}-#{suffix}.done")
  end

  @doc """
  Reads and validates a sentinel file.
  Returns `{:ok, result}` if the sentinel indicates completion,
  `:stale` if the commit hash matches the base commit (no progress),
  `:not_found` if the file doesn't exist.
  """
  @spec read_sentinel(String.t(), String.t() | nil) ::
          {:ok, sentinel_result()} | :stale | :not_found
  def read_sentinel(path, base_commit \\ nil) do
    case File.read(path) do
      {:ok, content} ->
        parse_and_validate(String.trim(content), base_commit)

      {:error, :enoent} ->
        :not_found

      {:error, reason} ->
        Logger.warning("Protocol: failed to read sentinel #{path}: #{inspect(reason)}")
        :not_found
    end
  end

  @doc """
  Writes a sentinel file indicating phase completion.
  """
  @spec write_sentinel(String.t(), map()) :: :ok | {:error, term()}
  def write_sentinel(path, data \\ %{}) do
    File.mkdir_p!(Path.dirname(path))

    content =
      if map_size(data) == 0 do
        "done"
      else
        result =
          Map.merge(
            %{status: "done", timestamp: DateTime.utc_now() |> DateTime.to_iso8601()},
            data
          )

        Jason.encode!(result)
      end

    File.write(path, content)
  end

  @doc """
  Removes a sentinel file (e.g., to force re-execution).
  """
  @spec remove_sentinel(String.t()) :: :ok | {:error, File.posix()}
  def remove_sentinel(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reads the verdict file for a review-gate phase.
  Returns `:pass`, `:pass_with_concerns`, or `:block`.
  """
  @spec read_review_verdict(String.t()) :: :pass | :pass_with_concerns | :block
  def read_review_verdict(path) do
    case File.read(path) do
      {:ok, content} ->
        cond do
          content =~ ~r/^GATE:\s*PASS_WITH_CONCERNS/mi -> :pass_with_concerns
          content =~ ~r/^GATE:\s*PASS/mi -> :pass
          content =~ ~r/^GATE:\s*BLOCK/mi -> :block
          content =~ ~r/STATUS:\s*\*?BLOCK/i -> :block
          true -> :block
        end

      {:error, _} ->
        :block
    end
  end

  @doc """
  Returns the verdict file path for a review-gate phase.
  """
  @spec verdict_path(String.t(), String.t(), String.t()) :: String.t()
  def verdict_path(runs_dir, run_id, phase_id) do
    Path.join(runs_dir, "#{run_id}-#{phase_id}.verdicts.md")
  end

  @doc """
  Reads team task snapshot from the Claude tasks directory.
  Returns counts of total, completed, in_progress, and pending tasks.
  """
  @spec read_team_tasks(String.t()) :: %{
          exists: boolean(),
          total: non_neg_integer(),
          completed: non_neg_integer(),
          in_progress: non_neg_integer(),
          pending: non_neg_integer(),
          all_completed: boolean()
        }
  def read_team_tasks(team_name) do
    task_dir = Path.expand("~/.claude/tasks/#{team_name}")

    if File.dir?(task_dir) do
      task_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.reduce(%{exists: true, total: 0, completed: 0, in_progress: 0, pending: 0}, fn file,
                                                                                             acc ->
        path = Path.join(task_dir, file)

        case path |> File.read!() |> Jason.decode() do
          {:ok, %{"status" => status}} ->
            acc
            |> Map.update!(:total, &(&1 + 1))
            |> Map.update!(String.to_existing_atom(status), &(&1 + 1))

          _ ->
            Map.update!(acc, :total, &(&1 + 1))
        end
      end)
      |> Map.put(:all_completed, false)
      |> then(fn m -> %{m | all_completed: m.total > 0 and m.completed == m.total} end)
    else
      %{exists: false, total: 0, completed: 0, in_progress: 0, pending: 0, all_completed: false}
    end
  end

  @doc """
  Waits for team task completion using hybrid PubSub + file polling.
  Subscribes to team events for instant notification, with filesystem
  polling as a fallback (30s default vs. previous 5s).
  Returns `{:ok, snapshot}` when all done, `{:error, :timeout}` on timeout.
  """
  @spec wait_for_team_basic(String.t(), keyword()) :: {:ok, map()} | {:error, :timeout}
  def wait_for_team_basic(team_name, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 600_000)
    poll_interval = Keyword.get(opts, :poll_interval_ms, 30_000)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    # Subscribe to team events for instant PubSub notification
    Events.subscribe_team(team_name)

    # Immediate check before entering wait loop
    snapshot = read_team_tasks(team_name)

    if snapshot.all_completed do
      {:ok, snapshot}
    else
      do_wait_for_team_hybrid(team_name, poll_interval, deadline)
    end
  end

  @doc """
  Checks if a team config file exists.
  """
  @spec team_config_exists?(String.t()) :: boolean()
  def team_config_exists?(team_name) do
    Path.expand("~/.claude/teams/#{team_name}/config.json") |> File.exists?()
  end

  # --- Private ---

  defp parse_and_validate(content, _base_commit)
       when content in ["done", "done (skip-if-planned)"] do
    {:ok, %{status: "done", commit_hash: nil, no_changes: false, execution_type: nil}}
  end

  defp parse_and_validate(content, base_commit) do
    case Jason.decode(content) do
      {:ok, data} ->
        commit_hash = Map.get(data, "commitHash")
        no_changes = Map.get(data, "noChanges", false)

        if stale?(commit_hash, base_commit, no_changes) do
          :stale
        else
          {:ok,
           %{
             status: Map.get(data, "status", "done"),
             commit_hash: commit_hash,
             no_changes: no_changes,
             execution_type: Map.get(data, "executionType")
           }}
        end

      {:error, _} ->
        Logger.warning("Protocol: unparseable sentinel content: #{String.slice(content, 0, 100)}")
        :not_found
    end
  end

  defp stale?(nil, _base, _no_changes), do: false
  defp stale?(_hash, nil, _no_changes), do: false
  defp stale?(hash, base, no_changes), do: hash == base and not no_changes

  defp do_wait_for_team_hybrid(team_name, poll_interval, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      wait_time = min(poll_interval, remaining)

      receive do
        {:team_completed, ^team_name, snapshot} ->
          {:ok, snapshot}

        {:team_update, ^team_name, snapshot} ->
          if snapshot.all_completed do
            {:ok, snapshot}
          else
            do_wait_for_team_hybrid(team_name, poll_interval, deadline)
          end
      after
        wait_time ->
          # Fallback: poll filesystem
          snapshot = read_team_tasks(team_name)

          if snapshot.all_completed do
            {:ok, snapshot}
          else
            do_wait_for_team_hybrid(team_name, poll_interval, deadline)
          end
      end
    end
  end
end
