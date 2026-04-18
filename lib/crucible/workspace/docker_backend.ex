defmodule Crucible.Workspace.DockerBackend do
  @moduledoc """
  Docker-based workspace backend for sandboxed tool execution.

  All file operations are executed inside a Docker container via `docker exec`.
  Paths are resolved relative to `/sandbox` inside the container.
  """
  @behaviour Crucible.Workspace.Backend

  @default_timeout_ms 30_000

  @impl true
  def read(path, opts \\ []) do
    container_id = Keyword.fetch!(opts, :container_id)
    resolved = resolve_path(path)

    case docker_exec(container_id, "cat #{resolved}", opts) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def write(path, content, opts \\ []) do
    container_id = Keyword.fetch!(opts, :container_id)
    resolved = resolve_path(path)

    # Ensure parent directory exists, then write via stdin pipe
    dir = Path.dirname(resolved)
    docker_exec(container_id, "mkdir -p #{dir}", opts)

    # Use base64 encoding to safely pass arbitrary content
    encoded = Base.encode64(content)

    case docker_exec(container_id, "echo '#{encoded}' | base64 -d > #{resolved}", opts) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def exec(command, opts \\ []) do
    container_id = Keyword.fetch!(opts, :container_id)
    docker_exec(container_id, command, opts)
  end

  @impl true
  def list(path, opts \\ []) do
    container_id = Keyword.fetch!(opts, :container_id)
    resolved = resolve_path(path)

    case docker_exec(container_id, "ls #{resolved}", opts) do
      {:ok, output} -> {:ok, String.split(output, "\n", trim: true)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def exists?(path, opts \\ []) do
    container_id = Keyword.fetch!(opts, :container_id)
    resolved = resolve_path(path)

    case docker_exec(container_id, "test -e #{resolved} && echo yes || echo no", opts) do
      {:ok, "yes" <> _} -> true
      _ -> false
    end
  end

  @impl true
  def delete(path, opts \\ []) do
    container_id = Keyword.fetch!(opts, :container_id)
    resolved = resolve_path(path)

    case docker_exec(container_id, "rm -f #{resolved}", opts) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def mkdir_p(path, opts \\ []) do
    container_id = Keyword.fetch!(opts, :container_id)
    resolved = resolve_path(path)

    case docker_exec(container_id, "mkdir -p #{resolved}", opts) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Private ---

  defp docker_exec(container_id, command, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    cwd = Keyword.get(opts, :cwd, "/sandbox")

    args = ["exec", "-w", cwd, container_id, "sh", "-c", command]

    task =
      Task.async(fn ->
        System.cmd("docker", args, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, code}} -> {:error, {:exit_code, code, output}}
      nil -> {:error, :timeout}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp resolve_path(path) do
    # All paths relative to /sandbox, prevent traversal
    clean = Path.expand(path, "/sandbox")

    if String.starts_with?(clean, "/sandbox") do
      clean
    else
      "/sandbox/#{Path.basename(path)}"
    end
  end
end
