defmodule CrucibleWeb.Api.CodebaseController do
  use CrucibleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  @codebase_dir "memory/codebase"

  operation(:index,
    summary: "List codebase modules",
    description: "Returns all indexed codebase module summaries from the memory vault.",
    tags: ["Codebase"],
    responses: [
      ok:
        {"Module list", "application/json",
         %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}}}
    ]
  )

  def index(conn, _params) do
    modules =
      if File.dir?(@codebase_dir) do
        Path.wildcard(Path.join(@codebase_dir, "**/*.md"))
        |> Enum.map(fn path ->
          name = path |> Path.basename(".md") |> String.replace_prefix("module-", "")
          %{name: name, path: path}
        end)
        |> Enum.sort_by(& &1.name)
      else
        []
      end

    json(conn, modules)
  end

  operation(:symbols,
    summary: "List codebase symbols",
    description: "Returns exported symbols from the indexed codebase (not yet implemented).",
    tags: ["Codebase"],
    responses: [
      ok:
        {"Symbol list", "application/json",
         %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}}}
    ]
  )

  def symbols(conn, _params), do: json(conn, [])

  operation(:references,
    summary: "List symbol references",
    description: "Returns reference locations for a symbol (not yet implemented).",
    tags: ["Codebase"],
    responses: [
      ok:
        {"Reference list", "application/json",
         %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}}}
    ]
  )

  def references(conn, _params), do: json(conn, [])

  operation(:callgraph,
    summary: "Get call graph",
    description: "Returns the codebase call graph as nodes and edges (not yet implemented).",
    tags: ["Codebase"],
    responses: [ok: {"Call graph", "application/json", %OpenApiSpex.Schema{type: :object}}]
  )

  def callgraph(conn, _params), do: json(conn, %{nodes: [], edges: []})

  operation(:impact,
    summary: "Get change impact",
    description:
      "Returns dependents and transitive dependents for a module (not yet implemented).",
    tags: ["Codebase"],
    responses: [ok: {"Impact analysis", "application/json", %OpenApiSpex.Schema{type: :object}}]
  )

  def impact(conn, _params), do: json(conn, %{dependents: [], transitives: []})

  operation(:codebase_health,
    summary: "Get codebase health score",
    description:
      "Returns a health score and policy violations for the codebase (not yet implemented).",
    tags: ["Codebase"],
    responses: [ok: {"Codebase health", "application/json", %OpenApiSpex.Schema{type: :object}}]
  )

  def codebase_health(conn, _params), do: json(conn, %{score: 0, violations: []})

  operation(:graph,
    summary: "Get dependency graph",
    description:
      "Returns the full module dependency graph as nodes and edges (not yet implemented).",
    tags: ["Codebase"],
    responses: [ok: {"Dependency graph", "application/json", %OpenApiSpex.Schema{type: :object}}]
  )

  def graph(conn, _params), do: json(conn, %{nodes: [], edges: []})
end
