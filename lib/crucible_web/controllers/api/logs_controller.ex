defmodule CrucibleWeb.Api.LogsController do
  use CrucibleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  tags(["Logs"])
  security([%{"cookieAuth" => []}])

  operation(:index,
    summary: "List log files",
    description: "Returns metadata for all .log and .jsonl files in the claude-flow logs directory.",
    responses: [
      ok:
        {"Log file list", "application/json",
         %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}}}
    ]
  )

  operation(:stream,
    summary: "Tail a log file",
    description: "Returns the last N lines of a named log file.",
    parameters: [
      file: [in: :query, type: :string, required: true, description: "Log filename"],
      lines: [
        in: :query,
        type: :integer,
        required: false,
        description: "Number of trailing lines to return (default 100)"
      ]
    ],
    responses: [
      ok: {"Log content", "application/json", %OpenApiSpex.Schema{type: :object}},
      not_found: {"File not found", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )

  @logs_dir ".claude-flow/logs"

  def index(conn, _params) do
    logs =
      if File.dir?(@logs_dir) do
        @logs_dir
        |> File.ls!()
        |> Enum.filter(&(String.ends_with?(&1, ".log") or String.ends_with?(&1, ".jsonl")))
        |> Enum.map(fn file ->
          path = Path.join(@logs_dir, file)
          stat = File.stat!(path)

          %{
            name: file,
            size: stat.size,
            modifiedAt: stat.mtime |> NaiveDateTime.from_erl!() |> NaiveDateTime.to_iso8601()
          }
        end)
        |> Enum.sort_by(& &1.modifiedAt, :desc)
      else
        []
      end

    json(conn, logs)
  end

  def stream(conn, params) do
    file = Map.get(params, "file", "")
    {:ok, lines} = get_int(params, "lines", 100)

    path = Path.join(@logs_dir, file)

    if File.exists?(path) and String.starts_with?(Path.expand(path), Path.expand(@logs_dir)) do
      content =
        path
        |> File.stream!()
        |> Enum.take(-lines)
        |> Enum.join()

      json(conn, %{file: file, lines: lines, content: content})
    else
      error_json(conn, 404, "not_found", "Resource not found")
    end
  end
end
