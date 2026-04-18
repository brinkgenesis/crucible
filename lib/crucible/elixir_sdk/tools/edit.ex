defmodule Crucible.ElixirSdk.Tools.Edit do
  @moduledoc """
  Replace exact text in an existing file.

  Mirrors Anthropic's built-in Edit tool: the `old_string` must match
  verbatim, must be unique (unless `replace_all` is true), and the file
  must already exist.
  """

  @behaviour Crucible.ElixirSdk.Tool

  @impl true
  def schema do
    %{
      name: "Edit",
      description: """
      Perform an exact string replacement on a file. The file must exist,
      `old_string` must appear exactly once (unless `replace_all: true`),
      and whitespace/indentation must match exactly.
      """,
      input_schema: %{
        type: "object",
        required: ["file_path", "old_string", "new_string"],
        properties: %{
          file_path: %{type: "string"},
          old_string: %{type: "string"},
          new_string: %{type: "string"},
          replace_all: %{type: "boolean", default: false}
        }
      }
    }
  end

  @impl true
  def run(%{"file_path" => path, "old_string" => old, "new_string" => new} = input, ctx) do
    if ctx.permission_mode == :plan do
      {:ok, "[plan mode] would edit #{path}"}
    else
      abs = resolve(path, ctx.cwd)
      replace_all? = Map.get(input, "replace_all", false)

      with {:ok, content} <- File.read(abs),
           {:ok, updated} <- replace(content, old, new, replace_all?),
           :ok <- File.write(abs, updated) do
        {:ok, "Edited #{abs}"}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def run(_, _), do: {:error, "Edit requires `file_path`, `old_string`, `new_string`."}

  defp resolve(path, cwd) do
    if Path.type(path) == :absolute, do: path, else: Path.join(cwd, path)
  end

  defp replace(content, old, new, true), do: {:ok, String.replace(content, old, new)}

  defp replace(content, old, new, false) do
    case count_occurrences(content, old) do
      0 -> {:error, "old_string not found in file"}
      1 -> {:ok, String.replace(content, old, new)}
      n -> {:error, "old_string occurs #{n} times — pass replace_all: true or disambiguate"}
    end
  end

  defp count_occurrences(haystack, needle) do
    haystack
    |> String.split(needle)
    |> length()
    |> Kernel.-(1)
  end
end
