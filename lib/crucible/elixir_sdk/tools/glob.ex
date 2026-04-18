defmodule Crucible.ElixirSdk.Tools.Glob do
  @moduledoc """
  Filesystem glob search scoped to the run's workspace.

  Uses Erlang's wildcard expander. Results are sorted by modification time
  (newest first) and capped at 1000 entries.
  """

  @behaviour Crucible.ElixirSdk.Tool

  @max_results 1000

  @impl true
  def schema do
    %{
      name: "Glob",
      description: """
      Find files by glob pattern (e.g. "**/*.ex", "lib/**/*.ts"). Returns
      matching paths sorted by modification time (newest first).
      """,
      input_schema: %{
        type: "object",
        required: ["pattern"],
        properties: %{
          pattern: %{type: "string", description: "Glob pattern."},
          path: %{type: "string", description: "Optional directory to search within."}
        }
      }
    }
  end

  @impl true
  def run(%{"pattern" => pattern} = input, ctx) do
    root =
      case Map.get(input, "path") do
        nil -> ctx.cwd
        p -> if Path.type(p) == :absolute, do: p, else: Path.join(ctx.cwd, p)
      end

    matches =
      Path.join(root, pattern)
      |> Path.wildcard()
      |> Enum.sort_by(&file_mtime/1, :desc)
      |> Enum.take(@max_results)

    output =
      case matches do
        [] -> "No matches."
        xs -> Enum.join(xs, "\n")
      end

    {:ok, output}
  rescue
    e -> {:error, Exception.message(e)}
  end

  def run(_, _), do: {:error, "Glob requires `pattern` string."}

  defp file_mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> {{0, 0, 0}, {0, 0, 0}}
    end
  end
end
