defmodule CrucibleWeb.CodebaseLive.Helpers do
  @moduledoc """
  Pure helper functions for `CrucibleWeb.CodebaseLive`.

  Contains extracted utility functions that operate on plain data (no socket
  state required). These cover:

    * **View validation** — normalizing and building view-mode paths
    * **Module filtering** — prefix and search filtering of module lists
    * **Intelligence queries** — hotspot analysis, symbol lookup, cross-references
    * **UI formatting** — HUD badge CSS classes for symbol kinds

  All functions are public so the parent LiveView can call them directly after
  importing or aliasing this module.
  """

  alias Crucible.CodebaseReader

  @valid_views ~w(list graph intelligence)

  # ---------------------------------------------------------------------------
  # View helpers
  # ---------------------------------------------------------------------------

  @doc """
  Normalizes a view mode string to one of the valid views (`"list"`, `"graph"`,
  `"intelligence"`). Falls back to `fallback`, then `"list"`.
  """
  @spec normalize_view_mode(String.t() | nil, String.t()) :: String.t()
  def normalize_view_mode(view, _fallback) when view in @valid_views, do: view
  def normalize_view_mode(_view, fallback) when fallback in @valid_views, do: fallback
  def normalize_view_mode(_view, _fallback), do: "list"

  @doc """
  Builds the LiveView patch path for a given view mode.
  """
  @spec codebase_path(String.t()) :: String.t()
  def codebase_path(view), do: "/codebase?view=#{view}"

  # ---------------------------------------------------------------------------
  # Module filtering
  # ---------------------------------------------------------------------------

  @doc """
  Loads and filters the module list for a project, applying optional prefix
  and search filters from the given assigns map.

  Expects `assigns` to contain `:filter_prefix` and `:search` keys.
  """
  @spec load_filtered_modules(String.t(), map()) :: list()
  def load_filtered_modules(project, assigns) do
    modules = CodebaseReader.list_modules(project)

    modules =
      if assigns.filter_prefix do
        Enum.filter(modules, &String.starts_with?(&1.path, assigns.filter_prefix))
      else
        modules
      end

    if assigns.search != "" do
      q = String.downcase(assigns.search)
      Enum.filter(modules, &String.contains?(String.downcase(&1.path), q))
    else
      modules
    end
  end

  # ---------------------------------------------------------------------------
  # Graph
  # ---------------------------------------------------------------------------

  @doc """
  Builds the force-directed graph data for a project, optionally scoped to a
  directory prefix.
  """
  @spec build_graph_data(String.t(), String.t() | nil) :: map()
  def build_graph_data(project, prefix) do
    opts = if prefix, do: [prefix: prefix], else: []
    CodebaseReader.build_graph(project, opts)
  end

  # ---------------------------------------------------------------------------
  # Intelligence
  # ---------------------------------------------------------------------------

  @doc """
  Converts a user-supplied intel type string to a safe atom.

  Returns `:hotspots` for unknown values.
  """
  @spec safe_intel_atom(String.t()) :: :hotspots | :symbols | :references
  def safe_intel_atom("hotspots"), do: :hotspots
  def safe_intel_atom("symbols"), do: :symbols
  def safe_intel_atom("references"), do: :references
  def safe_intel_atom(_), do: :hotspots

  @doc """
  Executes an intelligence query against the codebase index.

  ## Query types

    * `:hotspots` — returns top 30 modules sorted by symbol + dependency count
    * `:symbols` — returns symbols for a specific module (requires `params.file`)
    * `:references` — searches module edges for a symbol name (requires `params.symbol`)

  Returns `{:ok, results}` or `{:error, reason}`.
  """
  @spec fetch_intel(:hotspots | :symbols | :references, String.t(), map()) ::
          {:ok, list() | map()} | {:error, String.t()}
  def fetch_intel(type, project, params) do
    case type do
      :hotspots ->
        modules = CodebaseReader.list_modules(project)

        hotspots =
          modules
          |> Enum.map(fn m ->
            %{
              "path" => m.path,
              "symbols" => m.symbol_count,
              "exports" => m.exported_count,
              "deps" => m.dep_count
            }
          end)
          |> Enum.sort_by(&(-(&1["symbols"] + &1["deps"])))
          |> Enum.take(30)

        {:ok, hotspots}

      :symbols ->
        file = Map.get(params, :file, "")

        case CodebaseReader.get_module(file, project) do
          nil ->
            {:error, "Module not found: #{file}"}

          detail ->
            symbols =
              detail.symbols
              |> Enum.map(fn s ->
                %{
                  "name" => s.name,
                  "kind" => s.kind,
                  "line" => Map.get(s, :line),
                  "exported" => s.exported
                }
              end)

            {:ok, symbols}
        end

      :references ->
        symbol = Map.get(params, :symbol, "")

        if symbol == "" do
          {:error, "Enter a symbol name to search"}
        else
          modules = CodebaseReader.list_modules(project)

          refs =
            modules
            |> Enum.flat_map(fn m ->
              case CodebaseReader.get_module(m.path, project) do
                nil ->
                  []

                detail ->
                  detail.edges
                  |> Enum.filter(fn edge ->
                    Enum.any?(edge.names, &String.contains?(&1, symbol))
                  end)
                  |> Enum.map(fn edge ->
                    %{
                      "file" => m.path,
                      "context" => "imports #{Enum.join(edge.names, ", ")} from #{edge.target}"
                    }
                  end)
              end
            end)
            |> Enum.take(50)

          {:ok, refs}
        end

      _ ->
        {:error, "Unknown intelligence type"}
    end
  rescue
    e -> {:error, "Error: #{inspect(e)}"}
  end

  # ---------------------------------------------------------------------------
  # UI formatting
  # ---------------------------------------------------------------------------

  @doc """
  Returns HUD-themed CSS classes for a symbol kind badge.

  Maps symbol kinds (e.g. `"class"`, `"function"`, `"interface"`) to
  color/border utility classes for the tactical UI theme.
  """
  @spec kind_hud_badge(String.t()) :: String.t()
  def kind_hud_badge("class"), do: "text-[#ffa44c] border-[#ffa44c]/30"
  def kind_hud_badge("interface"), do: "text-[#00eefc] border-[#00eefc]/30"
  def kind_hud_badge("function"), do: "text-[#00FF41] border-[#00FF41]/30"
  def kind_hud_badge("method"), do: "text-[#00FF41] border-[#00FF41]/30"
  def kind_hud_badge("variable"), do: "text-[#ff725e] border-[#ff725e]/30"
  def kind_hud_badge("type"), do: "text-[#00eefc] border-[#00eefc]/30"
  def kind_hud_badge(_), do: "text-[#e0e0e0]/30 border-[#e0e0e0]/10"
end
