defmodule Crucible.ElixirSdk.Tools.Bash do
  @moduledoc """
  Execute a shell command in the run's workspace.

  Uses `System.cmd/3` with a hard timeout. Stdout and stderr are captured
  together. When `permission_mode` is `:plan`, commands are not executed
  — the input is echoed back so the model can plan.
  """

  @behaviour Crucible.ElixirSdk.Tool

  @default_timeout_ms 120_000

  @impl true
  def schema do
    %{
      name: "Bash",
      description: """
      Run a shell command in the workspace directory. Output is trimmed to
      the first ~20k bytes. Use for build, test, git, and filesystem
      operations not covered by Read/Write/Edit/Glob/Grep.
      """,
      input_schema: %{
        type: "object",
        required: ["command"],
        properties: %{
          command: %{type: "string", description: "Shell command to execute."},
          timeout: %{type: "integer", description: "Timeout in milliseconds (default 120000)."},
          description: %{type: "string", description: "Human-readable intent (optional)."}
        }
      }
    }
  end

  @impl true
  def run(%{"command" => command} = input, ctx) do
    if ctx.permission_mode == :plan do
      {:ok, "[plan mode] would run: #{command}"}
    else
      timeout = Map.get(input, "timeout", @default_timeout_ms)
      do_run(command, ctx.cwd, timeout)
    end
  end

  def run(_, _), do: {:error, "Bash requires `command` string."}

  defp do_run(command, cwd, timeout_ms) do
    task =
      Task.async(fn ->
        System.cmd("bash", ["-lc", command],
          cd: cwd,
          stderr_to_stdout: true,
          env: [{"TERM", "dumb"}]
        )
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {output, status}} ->
        {:ok, "[exit #{status}]\n#{output}"}

      nil ->
        {:error, "command timed out after #{timeout_ms}ms"}

      {:exit, reason} ->
        {:error, "command crashed: #{inspect(reason)}"}
    end
  end
end
