defmodule Crucible.CodebaseReader do
  @moduledoc """
  Stateless reader for codebase index JSON files.
  Reads from memory/.codebase-index-{project}.json on demand.
  """

  # Default to a sibling `memory/` directory under the working directory. The
  # vault path is runtime-configurable via `CRUCIBLE_VAULT_PATH` / the
  # :crucible :vault_path application env; the codebase index JSON files live
  # inside that directory as `.codebase-index-{project}.json`.
  @default_vault "memory"

  defp vault_path do
    Application.get_env(:crucible, :vault_path) ||
      System.get_env("CRUCIBLE_VAULT_PATH") ||
      @default_vault
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Lists all modules with summary info."
  def list_modules(project \\ "infra", opts \\ []) do
    case read_index(project, opts) do
      %{"entries" => entries} when is_map(entries) ->
        entries
        |> Enum.map(fn {path, entry} ->
          edges = Map.get(entry, "edges", [])
          symbols = get_in(entry, ["graph", "symbols"]) || []

          %{
            path: path,
            slug: Map.get(entry, "slug", ""),
            dep_count: length(edges),
            symbol_count: length(symbols),
            exported_count: Enum.count(symbols, &(&1["exported"] == true))
          }
        end)
        |> Enum.sort_by(& &1.path)

      _ ->
        []
    end
  end

  @doc "Returns full entry for a module path."
  def get_module(path, project \\ "infra", opts \\ []) do
    case read_index(project, opts) do
      %{"entries" => entries} when is_map(entries) ->
        case Map.get(entries, path) do
          nil -> nil
          entry -> normalize_entry(path, entry)
        end

      _ ->
        nil
    end
  end

  @doc "Builds graph data for ForceGraph hook."
  def build_graph(project \\ "infra", opts \\ []) do
    prefix = Keyword.get(opts, :prefix)

    case read_index(project, opts) do
      %{"entries" => entries} when is_map(entries) ->
        filtered =
          if prefix do
            entries
            |> Enum.filter(fn {path, _} -> String.starts_with?(path, prefix) end)
            |> Map.new()
          else
            entries
          end

        paths = MapSet.new(Map.keys(filtered))

        nodes =
          Enum.map(filtered, fn {path, _entry} ->
            %{
              id: path,
              label: Path.basename(path, Path.extname(path)),
              type: "codebase",
              group: path |> String.split("/") |> Enum.take(2) |> Enum.join("/")
            }
          end)

        edges =
          filtered
          |> Enum.flat_map(fn {_path, entry} ->
            Map.get(entry, "edges", [])
            |> Enum.filter(fn edge ->
              MapSet.member?(paths, edge["source"]) and MapSet.member?(paths, edge["target"])
            end)
            |> Enum.map(fn edge ->
              %{source: edge["source"], target: edge["target"]}
            end)
          end)
          |> Enum.uniq()

        %{nodes: nodes, edges: edges}

      _ ->
        %{nodes: [], edges: []}
    end
  end

  @doc "Returns dependency statistics."
  def dependency_stats(project \\ "infra", opts \\ []) do
    case read_index(project, opts) do
      %{"entries" => entries, "lastFullIndexMs" => last_indexed} when is_map(entries) ->
        all_edges =
          Enum.flat_map(entries, fn {_path, entry} -> Map.get(entry, "edges", []) end)

        # Count imports per source (most dependencies)
        import_counts =
          Enum.frequencies_by(all_edges, & &1["source"])
          |> Enum.sort_by(&elem(&1, 1), :desc)

        # Count how often each target is imported (most depended upon)
        imported_counts =
          Enum.frequencies_by(all_edges, & &1["target"])
          |> Enum.sort_by(&elem(&1, 1), :desc)

        top_importer =
          case import_counts do
            [{path, count} | _] -> "#{Path.basename(path)} (#{count})"
            _ -> "—"
          end

        top_imported =
          case imported_counts do
            [{path, count} | _] -> "#{Path.basename(path)} (#{count})"
            _ -> "—"
          end

        %{
          total_modules: map_size(entries),
          total_edges: length(all_edges),
          top_importer: top_importer,
          top_imported: top_imported,
          last_indexed: format_epoch_ms(last_indexed)
        }

      _ ->
        %{
          total_modules: 0,
          total_edges: 0,
          top_importer: "—",
          top_imported: "—",
          last_indexed: "—"
        }
    end
  end

  @doc "Reads the vault markdown note for a module."
  def read_module_note(slug, project \\ "infra", opts \\ []) do
    vault = Keyword.get(opts, :vault_path, vault_path())
    path = Path.join([vault, "codebase", project, "module-#{slug}.md"])

    if File.exists?(path) do
      content = File.read!(path)

      # Extract purpose section
      case Regex.run(~r/## Purpose\n(.*?)(?:\n##|\z)/s, content) do
        [_, purpose] -> String.trim(purpose)
        _ -> String.slice(content, 0, 500)
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  @doc "Lists available projects."
  def list_projects(opts \\ []) do
    vault = Keyword.get(opts, :vault_path, vault_path())

    Path.wildcard(Path.join(vault, ".codebase-index-*.json"))
    |> Enum.map(fn path ->
      path
      |> Path.basename(".json")
      |> String.replace_prefix(".codebase-index-", "")
    end)
    |> Enum.sort()
  end

  @doc "Returns top-level directory prefixes for filtering."
  def directory_prefixes(project \\ "infra", opts \\ []) do
    case read_index(project, opts) do
      %{"entries" => entries} when is_map(entries) ->
        entries
        |> Map.keys()
        |> Enum.map(fn path ->
          case String.split(path, "/") do
            [dir | _] -> dir <> "/"
            _ -> path
          end
        end)
        |> Enum.frequencies()
        |> Enum.sort_by(&elem(&1, 1), :desc)
        |> Enum.map(&elem(&1, 0))

      _ ->
        []
    end
  end

  @doc "Finds all modules that depend on a given path (reverse deps)."
  def dependents(path, project \\ "infra", opts \\ []) do
    case read_index(project, opts) do
      %{"entries" => entries} when is_map(entries) ->
        Enum.filter(entries, fn {_p, entry} ->
          Enum.any?(Map.get(entry, "edges", []), fn edge ->
            edge["target"] == path
          end)
        end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      _ ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp read_index(project, opts) do
    vault = Keyword.get(opts, :vault_path, vault_path())
    path = Path.join(vault, ".codebase-index-#{project}.json")

    if File.exists?(path) do
      case File.read!(path) |> Jason.decode() do
        {:ok, data} when is_map(data) -> data
        _ -> nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp normalize_entry(path, entry) do
    edges = Map.get(entry, "edges", [])
    graph = Map.get(entry, "graph", %{})
    symbols = Map.get(graph, "symbols", [])

    %{
      path: path,
      slug: Map.get(entry, "slug", ""),
      edges:
        Enum.map(edges, fn e ->
          %{
            target: e["target"],
            type: e["type"] || "imports",
            names: e["names"] || []
          }
        end),
      symbols:
        Enum.map(symbols, fn s ->
          %{
            name: s["name"],
            kind: s["kind"] || "unknown",
            exported: s["exported"] == true
          }
        end),
      symbol_count: length(symbols),
      dep_count: length(edges)
    }
  end

  defp format_epoch_ms(nil), do: "—"

  defp format_epoch_ms(ms) when is_number(ms) do
    case DateTime.from_unix(trunc(ms), :millisecond) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
      _ -> "—"
    end
  end

  defp format_epoch_ms(_), do: "—"
end
