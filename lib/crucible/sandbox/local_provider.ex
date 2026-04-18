defmodule Crucible.Sandbox.LocalProvider do
  @moduledoc """
  No-op sandbox provider for development.

  Returns a virtual sandbox ID but executes everything locally on the host.
  Used when `SANDBOX_MODE=local` (default) or when the sandbox feature flag is off.
  """
  @behaviour Crucible.Sandbox.Provider

  @default_timeout_ms 30_000

  @impl true
  def start_sandbox(_opts) do
    {:ok, "local-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"}
  end

  @impl true
  def stop_sandbox(_sandbox_id), do: :ok

  @impl true
  def exec(_sandbox_id, command, opts \\ []) do
    cwd = Keyword.get(opts, :cwd)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    cmd_opts = if cwd, do: [cd: cwd], else: []

    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", command], cmd_opts ++ [stderr_to_stdout: true])
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
  def status(_sandbox_id), do: :running
end
