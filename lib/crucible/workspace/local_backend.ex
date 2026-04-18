defmodule Crucible.Workspace.LocalBackend do
  @moduledoc """
  Local filesystem workspace backend. Default implementation.

  Wraps Elixir `File` module operations with consistent error handling,
  optional base directory scoping, and path traversal protection.

  ## exec/2 options

  - `:command` — shell string, executed via `sh -c`. Kept for backwards
    compatibility but logs a warning on each call because string interpolation
    into `sh -c` is a shell-injection vector.
  - `:args` — `{cmd, [arg, ...]}` tuple. Executes `cmd` directly via
    `System.cmd/3` with no shell. Preferred for production call sites.
  - `:base_dir` — working directory for the subprocess.
  - `:timeout_ms` — milliseconds before the task is killed (default 30 000).
  """

  require Logger

  @behaviour Crucible.Workspace.Backend

  @default_exec_timeout_ms 30_000

  @impl true
  def read(path, opts \\ []) do
    with {:ok, full_path} <- resolve(path, opts) do
      File.read(full_path)
    end
  end

  @impl true
  def write(path, content, opts \\ []) do
    with {:ok, full_path} <- resolve(path, opts) do
      File.mkdir_p!(Path.dirname(full_path))
      File.write(full_path, content)
    end
  end

  @impl true
  def exec(command_or_opts, opts \\ [])

  # Structured-args mode: exec({cmd, args}, opts)
  # Bypasses the shell entirely — no injection risk.
  def exec({cmd, args}, opts) when is_binary(cmd) and is_list(args) do
    run_task(cmd, args, opts)
  end

  # String-command mode: exec("shell string", opts)
  # Kept for backwards compat. Logs a warning because string interpolation
  # into sh -c is a shell-injection vector — callers should migrate to args mode.
  def exec(command, opts) when is_binary(command) do
    Logger.warning(
      "[LocalBackend] exec/2 called with shell string — prefer {:args} mode to avoid shell injection",
      command: command
    )

    run_task("sh", ["-c", command], opts)
  end

  defp run_task(cmd, args, opts) do
    cwd = Keyword.get(opts, :base_dir)
    timeout = Keyword.get(opts, :timeout_ms, @default_exec_timeout_ms)
    cmd_opts = if cwd, do: [cd: cwd], else: []

    task =
      Task.async(fn ->
        System.cmd(cmd, args, cmd_opts ++ [stderr_to_stdout: true])
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, code}} -> {:error, {:exit_code, code, output}}
      nil -> {:error, :timeout}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def list(path, opts \\ []) do
    with {:ok, full_path} <- resolve(path, opts) do
      case File.ls(full_path) do
        {:ok, entries} -> {:ok, entries}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def exists?(path, opts \\ []) do
    case resolve(path, opts) do
      {:ok, full_path} -> File.exists?(full_path)
      {:error, _} -> false
    end
  end

  @impl true
  def delete(path, opts \\ []) do
    with {:ok, full_path} <- resolve(path, opts) do
      File.rm(full_path)
    end
  end

  @impl true
  def mkdir_p(path, opts \\ []) do
    with {:ok, full_path} <- resolve(path, opts) do
      File.mkdir_p(full_path)
    end
  end

  # Path resolution with traversal protection.
  # When base_dir is set, ensures the resolved path stays within the base.
  defp resolve(path, opts) do
    case Keyword.get(opts, :base_dir) do
      nil ->
        {:ok, path}

      base ->
        joined = Path.join(base, path)
        expanded = Path.expand(joined)
        expanded_base = Path.expand(base)

        if String.starts_with?(expanded, expanded_base <> "/") or expanded == expanded_base do
          {:ok, expanded}
        else
          {:error, :path_traversal}
        end
    end
  end
end
