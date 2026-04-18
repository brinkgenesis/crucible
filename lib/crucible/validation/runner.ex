defmodule Crucible.Validation.Runner do
  @moduledoc """
  Runs validation checks in parallel after phase execution.
  Checks are executed concurrently via Task.async_stream.
  """

  @type check_result :: %{name: String.t(), status: :pass | :fail, message: String.t() | nil}
  @type result :: %{status: :pass | :fail, passed: [check_result()], failed: [check_result()]}

  @doc """
  Run a list of validation checks concurrently.

  ## Options
    * `:working_dir` — directory to run checks in
    * `:timeout_ms` — max time per check (default: 60_000)
    * `:run_id` — current run ID (for logging)
    * `:phase_id` — current phase ID (for logging)
  """
  @spec run_checks([map()], keyword()) :: result()
  def run_checks(checks, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 60_000)
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())

    results =
      checks
      |> Task.async_stream(
        fn check -> execute_check(check, working_dir, timeout) end,
        max_concurrency: 4,
        timeout: timeout + 5_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, :timeout} -> %{name: "timeout", status: :fail, message: "Check timed out"}
      end)

    {passed, failed} = Enum.split_with(results, &(&1.status == :pass))
    status = if failed == [], do: :pass, else: :fail

    %{status: status, passed: passed, failed: failed}
  end

  defp execute_check(%{"type" => "tsc"} = _check, working_dir, timeout) do
    run_command("npx tsc --noEmit", "tsc", working_dir, timeout)
  end

  defp execute_check(%{"type" => "vitest"} = _check, working_dir, timeout) do
    run_command("npx vitest run", "vitest", working_dir, timeout)
  end

  defp execute_check(%{"type" => "mix_test"} = _check, working_dir, timeout) do
    run_command("mix test", "mix_test", working_dir, timeout)
  end

  defp execute_check(%{"type" => "mix_compile"} = _check, working_dir, timeout) do
    run_command("mix compile --warnings-as-errors", "mix_compile", working_dir, timeout)
  end

  defp execute_check(%{"type" => "custom", "command" => cmd} = check, working_dir, timeout) do
    name = Map.get(check, "name", cmd)
    run_command(cmd, name, working_dir, timeout)
  end

  defp execute_check(check, _working_dir, _timeout) do
    %{name: inspect(check), status: :fail, message: "Unknown check type"}
  end

  defp run_command(cmd, name, working_dir, _timeout) do
    case System.cmd("sh", ["-c", cmd],
           cd: working_dir,
           stderr_to_stdout: true,
           env: [{"MIX_ENV", "test"}]
         ) do
      {_output, 0} ->
        %{name: name, status: :pass, message: nil}

      {output, code} ->
        truncated = String.slice(output, -500, 500)
        %{name: name, status: :fail, message: "Exit #{code}: #{truncated}"}
    end
  rescue
    e ->
      %{name: name, status: :fail, message: "Error: #{Exception.message(e)}"}
  end
end
