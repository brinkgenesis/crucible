defmodule CrucibleWeb.Api.AgentsController do
  use CrucibleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  # Agent YAML definitions live at the repo root under .claude/agents/
  defp agents_dir do
    Application.get_env(:crucible, :agents_dir, Path.expand(".claude/agents"))
  end

  operation(:index,
    summary: "List agent definitions",
    description: "Returns all agent YAML definitions found in the agents directory.",
    tags: ["Agents"],
    responses: [
      ok:
        {"Agent list", "application/json",
         %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}}}
    ]
  )

  def index(conn, _params) do
    agents =
      if File.dir?(agents_dir()) do
        agents_dir()
        |> File.ls!()
        |> Enum.filter(&(String.ends_with?(&1, ".yml") or String.ends_with?(&1, ".yaml")))
        |> Enum.map(&parse_agent_file/1)
        |> Enum.reject(&is_nil/1)
      else
        []
      end

    json(conn, agents)
  rescue
    _ -> json(conn, [])
  end

  operation(:show,
    summary: "Get agent definition",
    description: "Returns the raw YAML content of a named agent definition.",
    tags: ["Agents"],
    parameters: [
      name: [
        in: :path,
        type: :string,
        required: true,
        description: "Agent name (without file extension)"
      ]
    ],
    responses: [
      ok: {"Agent definition", "application/json", %OpenApiSpex.Schema{type: :object}},
      not_found: {"Not found", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def show(conn, %{"name" => name}) do
    # Sanitize name to prevent path traversal
    safe_name = Path.basename(name)
    path = Path.join(agents_dir(), "#{safe_name}.yml")
    alt_path = Path.join(agents_dir(), "#{safe_name}.yaml")

    cond do
      File.exists?(path) ->
        content = File.read!(path)
        json(conn, %{name: safe_name, raw: content})

      File.exists?(alt_path) ->
        content = File.read!(alt_path)
        json(conn, %{name: safe_name, raw: content})

      true ->
        error_json(conn, 404, "not_found", "Resource not found")
    end
  end

  operation(:stats,
    summary: "Agent lifecycle stats",
    description:
      "Returns event counts and last-seen timestamps aggregated by agent type from recent traces.",
    tags: ["Agents"],
    responses: [
      ok:
        {"Agent stats", "application/json",
         %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}}}
    ]
  )

  def stats(conn, _params) do
    # Read agent lifecycle stats from traces
    alias Crucible.TraceReader
    events = TraceReader.all_events(limit: 2000)

    by_agent =
      events
      |> Enum.filter(fn e -> Map.has_key?(e, "agentType") end)
      |> Enum.group_by(fn e -> Map.get(e, "agentType", "unknown") end)
      |> Enum.map(fn {agent, evts} ->
        %{
          agentType: agent,
          eventCount: length(evts),
          lastSeen: List.last(evts) |> Map.get("timestamp")
        }
      end)

    json(conn, by_agent)
  end

  defp parse_agent_file(filename) do
    path = Path.join(agents_dir(), filename)
    name = Path.rootname(filename)

    case File.read(path) do
      {:ok, content} ->
        %{name: name, filename: filename, raw: content}

      _ ->
        nil
    end
  end
end
