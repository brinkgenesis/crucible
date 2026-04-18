defmodule Crucible.ElixirSdk.Tools.NotebookEdit do
  @moduledoc """
  Edit cells in a Jupyter notebook (.ipynb).

  Supports three edit modes (mirroring the Anthropic SDK's NotebookEdit):

    * `"replace"` — overwrite the cell at `cell_number` with `new_source`.
    * `"insert"` — insert a new cell of `cell_type` at `cell_number`.
    * `"delete"` — remove the cell at `cell_number`.

  Cell numbering is 0-based. `cell_type` defaults to `"code"`.
  Outputs and execution counts on the affected cell are cleared.
  """

  @behaviour Crucible.ElixirSdk.Tool

  @impl true
  def schema do
    %{
      name: "NotebookEdit",
      description: """
      Modify Jupyter notebook cells by 0-based index. Use mode="replace"
      to update cell source, mode="insert" to add a new cell, or
      mode="delete" to remove one.
      """,
      input_schema: %{
        type: "object",
        required: ["notebook_path", "cell_number"],
        properties: %{
          notebook_path: %{type: "string", description: "Path to the .ipynb file."},
          cell_number: %{type: "integer", description: "0-based cell index."},
          new_source: %{type: "string", description: "Replacement / new cell source."},
          cell_type: %{type: "string", enum: ["code", "markdown"], default: "code"},
          edit_mode: %{type: "string", enum: ["replace", "insert", "delete"], default: "replace"}
        }
      }
    }
  end

  @impl true
  def run(%{"notebook_path" => path, "cell_number" => n} = input, ctx) do
    if ctx.permission_mode == :plan do
      {:ok, "[plan mode] would edit cell #{n} of #{path}"}
    else
      abs = resolve(path, ctx.cwd)
      mode = Map.get(input, "edit_mode", "replace")

      with {:ok, content} <- File.read(abs),
           {:ok, notebook} <- Jason.decode(content),
           {:ok, updated} <- apply_edit(notebook, n, mode, input),
           {:ok, encoded} <- Jason.encode(updated, pretty: true),
           :ok <- File.write(abs, encoded) do
        {:ok, "Notebook #{abs}: #{mode} cell #{n}"}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def run(_, _), do: {:error, "NotebookEdit requires `notebook_path` and `cell_number`."}

  # ── edit modes ───────────────────────────────────────────────────────────

  defp apply_edit(%{"cells" => cells} = nb, n, "replace", input) do
    if n >= length(cells) do
      {:error, "cell_number #{n} out of range (#{length(cells)} cells)"}
    else
      new_src = Map.get(input, "new_source", "")
      updated_cells = List.update_at(cells, n, &replace_cell_source(&1, new_src))
      {:ok, Map.put(nb, "cells", updated_cells)}
    end
  end

  defp apply_edit(%{"cells" => cells} = nb, n, "insert", input) do
    if n > length(cells) do
      {:error, "cell_number #{n} past end (#{length(cells)} cells)"}
    else
      cell = new_cell(Map.get(input, "cell_type", "code"), Map.get(input, "new_source", ""))
      updated_cells = List.insert_at(cells, n, cell)
      {:ok, Map.put(nb, "cells", updated_cells)}
    end
  end

  defp apply_edit(%{"cells" => cells} = nb, n, "delete", _input) do
    if n >= length(cells) do
      {:error, "cell_number #{n} out of range (#{length(cells)} cells)"}
    else
      {:ok, Map.put(nb, "cells", List.delete_at(cells, n))}
    end
  end

  defp apply_edit(_nb, _n, mode, _input) do
    {:error, "unknown edit_mode #{inspect(mode)} — use replace, insert, or delete"}
  end

  # ── cell helpers ────────────────────────────────────────────────────────

  defp replace_cell_source(cell, source) do
    cell
    |> Map.put("source", to_source_list(source))
    |> Map.put("outputs", [])
    |> Map.put("execution_count", nil)
  end

  defp new_cell("markdown", source) do
    %{
      "cell_type" => "markdown",
      "metadata" => %{},
      "source" => to_source_list(source)
    }
  end

  defp new_cell(_, source) do
    %{
      "cell_type" => "code",
      "metadata" => %{},
      "source" => to_source_list(source),
      "outputs" => [],
      "execution_count" => nil
    }
  end

  # ipynb stores sources as a list of lines (each with trailing newline) or
  # a single string. We use the list form for portability.
  defp to_source_list(nil), do: [""]
  defp to_source_list(""), do: [""]
  defp to_source_list(src) when is_binary(src) do
    src
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.map(fn {line, idx} ->
      if idx == 0, do: line <> "\n", else: line <> "\n"
    end)
    |> Enum.drop(-1)
    |> case do
      [] -> [src]
      xs -> xs
    end
  end

  defp resolve(path, cwd) do
    if Path.type(path) == :absolute, do: path, else: Path.join(cwd, path)
  end
end
