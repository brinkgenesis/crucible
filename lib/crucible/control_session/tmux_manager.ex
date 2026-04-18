defmodule Crucible.ControlSession.TmuxManager do
  @moduledoc """
  Handles all tmux interactions for control sessions.

  Responsible for creating, killing, and reading from tmux panes,
  as well as waiting for Claude Code to signal readiness.
  """

  require Logger

  @doc "Creates a tmux session, launches Claude, and waits for it to be ready."
  @spec spawn(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def spawn(session_name, cwd, model) do
    unless File.dir?(cwd) do
      throw({:error, :invalid_cwd})
    end

    case System.cmd(
           "tmux",
           ["new-session", "-d", "-s", session_name, "-c", cwd, "-x", "200", "-y", "50"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        System.cmd("tmux", ["set-option", "-t", session_name, "history-limit", "5000"],
          stderr_to_stdout: true
        )

        model_flag = if model && model != "", do: " --model #{model}", else: ""

        cmd =
          "unset ANTHROPIC_API_KEY; CLAUDECODE= claude --permission-mode bypassPermissions#{model_flag}"

        case System.cmd("tmux", ["send-keys", "-t", session_name, cmd, "Enter"],
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            wait_for_ready(session_name, 60_000)

          {err, _} ->
            {:error, {:send_failed, err}}
        end

      {err, _} ->
        {:error, {:tmux_create_failed, err}}
    end
  catch
    {:error, reason} -> {:error, reason}
  end

  @doc "Kills a tmux session by name, ignoring errors."
  @spec kill(String.t()) :: :ok
  def kill(session_name) do
    System.cmd("tmux", ["kill-session", "-t", session_name], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  @doc "Captures the full pane contents for a session (up to 500 lines back)."
  @spec capture_pane(String.t()) :: String.t()
  def capture_pane(session_name) do
    case System.cmd("tmux", ["capture-pane", "-p", "-S", "-500", "-t", session_name],
           stderr_to_stdout: true
         ) do
      {output, 0} -> output
      _ -> ""
    end
  rescue
    _ -> ""
  end

  @doc "Captures the last N meaningful lines from a session's pane."
  @spec capture_pane_tail(String.t(), non_neg_integer()) :: String.t()
  def capture_pane_tail(session_name, lines) do
    output = capture_pane(session_name)

    output
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> Enum.reverse()
    |> Enum.reject(&decorative_line?/1)
    |> Enum.take(-lines)
    |> Enum.join("\n")
  end

  @doc "Returns true if the tmux session is alive (exits with code 0)."
  @spec session_alive?(String.t()) :: boolean()
  def session_alive?(session_name) do
    case System.cmd("tmux", ["has-session", "-t", session_name], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  # --- Private ---

  defp wait_for_ready(session_name, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_ready(session_name, deadline)
  end

  defp do_wait_ready(session_name, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :ready_timeout}
    else
      output = capture_pane(session_name)

      if claude_ready?(output) do
        :ok
      else
        Process.sleep(2_000)
        do_wait_ready(session_name, deadline)
      end
    end
  end

  defp claude_ready?(output) do
    lines =
      output
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(-5)

    has_prompt =
      Enum.any?(lines, fn line ->
        (String.contains?(line, "❯") or String.ends_with?(line, ">")) and
          not String.contains?(line, "@teammate")
      end)

    has_signal =
      Enum.any?(lines, fn line ->
        String.contains?(line, "$") or String.contains?(line, "token") or
          String.contains?(line, "bypass") or String.contains?(line, "/help")
      end) or String.contains?(output, "permission")

    has_prompt and has_signal
  end

  # Only filter lines that are purely decorative separators (long runs of ─ chars).
  # Preserves empty lines, prompts, and all actual content.
  defp decorative_line?(line) do
    trimmed = String.trim(line)

    String.length(trimmed) >= 10 and
      String.replace(trimmed, ~r/[─━═┄┈╌╍▬—–\-│┌┐└┘├┤┬┴┼╭╮╰╯]/, "")
      |> String.trim()
      |> then(fn rest -> String.length(rest) <= 2 end)
  end
end
