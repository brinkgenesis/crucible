defmodule Crucible.Sandbox.DockerProvider do
  @moduledoc """
  Docker-based sandbox provider for production.

  Each sandbox is a Docker container with policy-enforced filesystem,
  network, and process restrictions. Tool calls execute via `docker exec`.
  """
  @behaviour Crucible.Sandbox.Provider

  require Logger

  alias Crucible.Sandbox.Policy

  @default_timeout_ms 30_000

  @impl true
  def start_sandbox(opts) do
    %{workspace_path: workspace_path, policy: policy, image: image, labels: labels} = opts
    name = "sandbox-#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}"

    flags =
      Policy.docker_flags(policy, workspace_path: workspace_path) ++
        ["-w", "/sandbox", "--name", name] ++
        label_flags(labels) ++
        ["-d", image, "sleep", "infinity"]

    args = ["run"] ++ flags

    case System.cmd("docker", args, stderr_to_stdout: true) do
      {container_id, 0} ->
        Logger.info("Sandbox started: #{name} (#{String.trim(container_id)})")
        {:ok, name}

      {output, code} ->
        Logger.error("Sandbox start failed (exit #{code}): #{output}")
        {:error, {:docker_run_failed, code, output}}
    end
  end

  @impl true
  def stop_sandbox(sandbox_id) do
    case System.cmd("docker", ["rm", "-f", sandbox_id], stderr_to_stdout: true) do
      {_, 0} ->
        Logger.info("Sandbox stopped: #{sandbox_id}")
        :ok

      {output, code} ->
        Logger.warning("Sandbox stop failed (exit #{code}): #{output}")
        {:error, {:docker_rm_failed, code, output}}
    end
  end

  @impl true
  def exec(sandbox_id, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    cwd = Keyword.get(opts, :cwd, "/sandbox")

    args = ["exec", "-w", cwd, sandbox_id, "sh", "-c", command]
    start_time = System.monotonic_time(:millisecond)

    task =
      Task.async(fn ->
        System.cmd("docker", args, stderr_to_stdout: true)
      end)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {output, 0}} -> {:ok, output}
        {:ok, {output, code}} -> {:error, {:exit_code, code, output}}
        nil -> {:error, :timeout}
      end

    duration_ms = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      [:infra, :sandbox, :exec],
      %{duration_ms: duration_ms},
      %{sandbox_id: sandbox_id, success: match?({:ok, _}, result)}
    )

    result
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def status(sandbox_id) do
    case System.cmd("docker", ["inspect", "--format", "{{.State.Status}}", sandbox_id],
           stderr_to_stdout: true
         ) do
      {"running\n", 0} -> :running
      {_, 0} -> :stopped
      _ -> :unknown
    end
  end

  defp label_flags(labels) when is_map(labels) do
    Enum.flat_map(labels, fn {k, v} -> ["--label", "#{k}=#{v}"] end)
  end

  defp label_flags(_), do: []
end
