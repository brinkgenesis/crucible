defmodule Crucible.ElixirSdk.Tools.Read do
  @moduledoc "Read the contents of a file from the workspace."

  @behaviour Crucible.ElixirSdk.Tool

  @impl true
  def schema do
    %{
      name: "Read",
      description: """
      Read a file from the filesystem and return its contents prefixed with
      1-based line numbers. Use absolute paths or paths relative to the run's
      workspace.
      """,
      input_schema: %{
        type: "object",
        required: ["file_path"],
        properties: %{
          file_path: %{type: "string", description: "Absolute or workspace-relative path."},
          offset: %{type: "integer", description: "Optional 1-based starting line."},
          limit: %{type: "integer", description: "Optional maximum number of lines to read."}
        }
      }
    }
  end

  @impl true
  def run(%{"file_path" => path} = input, ctx) do
    abs = resolve(path, ctx.cwd)

    with {:ok, contents} <- File.read(abs) do
      lines = String.split(contents, "\n")
      offset = Map.get(input, "offset", 1)
      limit = Map.get(input, "limit", 2000)

      selected =
        lines
        |> Enum.drop(max(offset - 1, 0))
        |> Enum.take(limit)

      output =
        selected
        |> Enum.with_index(offset)
        |> Enum.map_join("\n", fn {line, n} ->
          :io_lib.format("~5w\t~s", [n, line]) |> IO.iodata_to_binary()
        end)

      {:ok, output}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def run(_, _), do: {:error, "Read requires a `file_path` string."}

  defp resolve(path, cwd) do
    if Path.type(path) == :absolute, do: path, else: Path.join(cwd, path)
  end
end
