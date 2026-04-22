defmodule CrucibleWeb.Api.TeamsController do
  use CrucibleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  @teams_dir Path.expand("~/.claude/teams")

  operation(:index,
    summary: "List agent teams",
    description: "Returns all agent teams with member counts and descriptions.",
    tags: ["Teams"],
    responses: [
      ok:
        {"Teams list", "application/json",
         %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}}}
    ]
  )

  def index(conn, _params) do
    teams =
      if File.dir?(@teams_dir) do
        @teams_dir
        |> File.ls!()
        |> Enum.filter(&File.dir?(Path.join(@teams_dir, &1)))
        |> Enum.map(fn name ->
          config = read_team_config(name)

          %{
            name: name,
            members: length(Map.get(config, "members", [])),
            description: Map.get(config, "description")
          }
        end)
      else
        []
      end

    json(conn, teams)
  end

  operation(:show,
    summary: "Get team config",
    description: "Returns the full configuration for a named agent team.",
    tags: ["Teams"],
    parameters: [
      name: [in: :path, type: :string, required: true, description: "Team name"]
    ],
    responses: [
      ok: {"Team config", "application/json", %OpenApiSpex.Schema{type: :object}},
      not_found: {"Not found", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  def show(conn, %{"name" => name}) do
    case read_team_config(name) do
      config when config != %{} -> json(conn, config)
      _ -> error_json(conn, 404, "not_found", "Resource not found")
    end
  end

  operation(:members,
    summary: "List team members",
    description: "Returns the member list from a team's configuration.",
    tags: ["Teams"],
    parameters: [
      name: [in: :path, type: :string, required: true, description: "Team name"]
    ],
    responses: [
      ok:
        {"Team members", "application/json",
         %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}}}
    ]
  )

  def members(conn, %{"name" => name}) do
    config = read_team_config(name)
    json(conn, Map.get(config, "members", []))
  end

  operation(:tasks,
    summary: "List team tasks",
    description: "Returns all task JSON files for a given team.",
    tags: ["Teams"],
    parameters: [
      name: [in: :path, type: :string, required: true, description: "Team name"]
    ],
    responses: [
      ok:
        {"Team tasks", "application/json",
         %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}}}
    ]
  )

  def tasks(conn, %{"name" => name}) do
    tasks_dir = Path.join([Path.expand("~/.claude/tasks"), name])

    tasks =
      if File.dir?(tasks_dir) do
        tasks_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(fn file ->
          path = Path.join(tasks_dir, file)

          case Jason.decode(File.read!(path)) do
            {:ok, task} -> task
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
      else
        []
      end

    json(conn, tasks)
  rescue
    _ -> json(conn, [])
  end

  defp read_team_config(name) do
    path = Path.join([@teams_dir, name, "config.json"])

    if File.exists?(path) do
      case Jason.decode(File.read!(path)) do
        {:ok, config} -> config
        _ -> %{}
      end
    else
      %{}
    end
  rescue
    _ -> %{}
  end
end
