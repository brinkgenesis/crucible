defmodule Crucible.ExecutorLock do
  @moduledoc """
  PID-verified file-based executor lock.
  Prevents multiple orchestrator instances from running phases concurrently.
  Maps to `acquireExecutorLock` / `releaseExecutorLock` in lib/cli/workflow/executor.ts.
  """

  require Logger

  @lock_dir ".claude-flow"
  @lock_file "executor.lock"
  @counter_file "executor-fence.counter"
  @stale_ms 60_000

  @type lock_data :: %{
          pid: integer(),
          started_at: integer(),
          heartbeat_at: integer(),
          fence_id: integer()
        }

  @doc "Acquire the executor lock. Returns `{:ok, lock_data}` or `{:error, :locked}`."
  @spec acquire(String.t()) :: {:ok, lock_data()} | {:error, :locked}
  def acquire(infra_home \\ ".") do
    lock_path = lock_path(infra_home)
    File.mkdir_p!(Path.dirname(lock_path))

    case read_lock(lock_path) do
      {:ok, existing} ->
        if stale?(existing) or not pid_alive?(existing.pid) do
          Logger.info("ExecutorLock: reclaiming stale lock (pid=#{existing.pid})")
          write_lock(infra_home, lock_path)
        else
          {:error, :locked}
        end

      :not_found ->
        write_lock(infra_home, lock_path)
    end
  end

  @doc "Release the executor lock if owned by this process."
  @spec release(String.t()) :: :ok
  def release(infra_home \\ ".") do
    lock_path = lock_path(infra_home)
    my_pid = self_pid()

    case read_lock(lock_path) do
      {:ok, %{pid: ^my_pid}} ->
        File.rm(lock_path)
        :ok

      _ ->
        :ok
    end
  end

  @doc "Refresh the heartbeat timestamp on the lock."
  @spec heartbeat(String.t()) :: :ok | {:error, :not_owner}
  def heartbeat(infra_home \\ ".") do
    lock_path = lock_path(infra_home)
    my_pid = self_pid()

    case read_lock(lock_path) do
      {:ok, %{pid: ^my_pid} = data} ->
        updated = %{data | heartbeat_at: now_ms()}
        write_lock_data(lock_path, updated)
        :ok

      _ ->
        {:error, :not_owner}
    end
  end

  @doc "Check if a system PID is alive."
  @spec pid_alive?(integer()) :: boolean()
  def pid_alive?(pid) do
    case System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc "Read the current lock data (if any)."
  @spec read_lock(String.t()) :: {:ok, lock_data()} | :not_found
  def read_lock(lock_path) do
    case File.read(lock_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"pid" => pid, "startedAt" => s, "heartbeatAt" => h, "fenceId" => f}} ->
            {:ok, %{pid: pid, started_at: s, heartbeat_at: h, fence_id: f}}

          _ ->
            :not_found
        end

      {:error, _} ->
        :not_found
    end
  end

  # --- Private ---

  defp lock_path(infra_home), do: Path.join([infra_home, @lock_dir, @lock_file])

  defp write_lock(infra_home, lock_path) do
    fence_id = next_fence_id(infra_home)

    data = %{
      pid: self_pid(),
      started_at: now_ms(),
      heartbeat_at: now_ms(),
      fence_id: fence_id
    }

    write_lock_data(lock_path, data)
    {:ok, data}
  end

  defp write_lock_data(lock_path, data) do
    json =
      Jason.encode!(%{
        pid: data.pid,
        startedAt: data.started_at,
        heartbeatAt: data.heartbeat_at,
        fenceId: data.fence_id
      })

    File.write!(lock_path, json)
  end

  defp next_fence_id(infra_home) do
    counter_path = Path.join([infra_home, @lock_dir, @counter_file])

    current =
      case File.read(counter_path) do
        {:ok, content} ->
          case Integer.parse(String.trim(content)) do
            {n, _} -> n
            :error -> 0
          end

        _ ->
          0
      end

    next = current + 1
    File.write!(counter_path, to_string(next))
    next
  end

  defp stale?(%{heartbeat_at: hb}), do: now_ms() - hb > @stale_ms

  defp now_ms, do: System.system_time(:millisecond)

  defp self_pid do
    System.pid() |> String.trim() |> String.to_integer()
  end
end
