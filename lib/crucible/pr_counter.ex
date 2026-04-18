defmodule Crucible.PrCounter do
  @moduledoc """
  Reads PR signal files written by coder subagents.

  Each coder writes a signal file after opening a PR:

      {signals_dir}/{run_id}.pr-{role}.json
      {"pr_url": "...", "role": "coder-backend", "branch": "..."}

  The executor reads these at the phase boundary (after sprint phase
  completes, before PR shepherd starts). No background process needed —
  the phase transition is the synchronization point.
  """

  @default_signals_dir ".claude-flow/signals"

  @doc "Returns parsed signal data for all PR signal files for a run."
  @spec read(String.t(), String.t()) :: [map()]
  def read(run_id, signals_dir \\ @default_signals_dir) do
    signals_dir
    |> Path.join("#{run_id}.pr-*.json")
    |> Path.wildcard()
    |> Enum.flat_map(&parse_signal/1)
  end

  @doc "Returns just the PR URLs for a run."
  @spec urls(String.t(), String.t()) :: [String.t()]
  def urls(run_id, signals_dir \\ @default_signals_dir) do
    run_id |> read(signals_dir) |> Enum.map(& &1["pr_url"])
  end

  @doc "Checks whether all expected PRs have been signaled."
  @spec ready?(String.t(), pos_integer(), String.t()) :: boolean()
  def ready?(run_id, expected, signals_dir \\ @default_signals_dir) do
    length(read(run_id, signals_dir)) >= expected
  end

  @doc "Removes all PR signal files for a run."
  @spec cleanup(String.t(), String.t()) :: :ok
  def cleanup(run_id, signals_dir \\ @default_signals_dir) do
    signals_dir
    |> Path.join("#{run_id}.pr-*.json")
    |> Path.wildcard()
    |> Enum.each(&File.rm/1)
  end

  @doc "Returns the signal file path a coder should write to."
  @spec signal_path(String.t(), String.t(), String.t()) :: String.t()
  def signal_path(run_id, role, signals_dir \\ @default_signals_dir) do
    Path.join(signals_dir, "#{run_id}.pr-#{role}.json")
  end

  defp parse_signal(path) do
    with {:ok, content} <- File.read(path),
         {:ok, data} when is_map(data) <- Jason.decode(content) do
      [data]
    else
      _ -> []
    end
  end
end
