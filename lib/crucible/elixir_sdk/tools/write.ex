defmodule Crucible.ElixirSdk.Tools.Write do
  @moduledoc "Write content to a file. Creates parent directories."

  @behaviour Crucible.ElixirSdk.Tool

  @impl true
  def schema do
    %{
      name: "Write",
      description: """
      Write the entire `content` to `file_path`, overwriting if it exists.
      Creates parent directories. Use Edit for targeted changes to existing
      files; Write is for new files or full replacements.
      """,
      input_schema: %{
        type: "object",
        required: ["file_path", "content"],
        properties: %{
          file_path: %{type: "string", description: "Absolute or workspace-relative path."},
          content: %{type: "string", description: "Full file content to write."}
        }
      }
    }
  end

  @impl true
  def run(%{"file_path" => path, "content" => content}, ctx) do
    if ctx.permission_mode == :plan do
      {:ok, "[plan mode] would write #{byte_size(content)} bytes to #{path}"}
    else
      abs = resolve(path, ctx.cwd)
      with :ok <- File.mkdir_p(Path.dirname(abs)),
           :ok <- File.write(abs, content) do
        {:ok, "Wrote #{byte_size(content)} bytes to #{abs}"}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def run(_, _), do: {:error, "Write requires `file_path` and `content` strings."}

  defp resolve(path, cwd) do
    if Path.type(path) == :absolute, do: path, else: Path.join(cwd, path)
  end
end
