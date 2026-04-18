defmodule CrucibleWeb.Api.RemoteController do
  use CrucibleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Crucible.RemoteSessionTracker

  require Logger

  operation(:start,
    summary: "Start remote Claude session",
    description: "Launches a new remote Claude Code session and returns its session details.",
    tags: ["Remote"],
    responses: [
      ok: {"Session started", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]
  )
  def start(conn, params) do
    start_opts =
      []
      |> maybe_put(:cwd, params["cwd"])
      |> maybe_put(:permission_mode, params["permission_mode"])

    case RemoteSessionTracker.start_session(start_opts) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :claude_not_found} ->
        conn
        |> put_status(500)
        |> json(%{error: "claude_not_found", message: "`claude` executable is not available"})

      {:error, reason} ->
        Logger.error("RemoteController: failed to start remote session: #{inspect(reason)}")
        conn |> put_status(500) |> json(%{error: "start_failed"})
    end
  end

  operation(:status,
    summary: "Get remote session status",
    description: "Returns whether a remote Claude session is currently running and its metadata.",
    tags: ["Remote"],
    responses: [ok: {"Session status", "application/json", %OpenApiSpex.Schema{type: :object}}]
  )
  def status(conn, _params) do
    json(conn, RemoteSessionTracker.status())
  end

  operation(:stop,
    summary: "Stop remote session",
    description: "Terminates the active remote Claude session.",
    tags: ["Remote"],
    responses: [ok: {"Session stopped", "application/json", %OpenApiSpex.Schema{type: :object}}]
  )
  def stop(conn, _params) do
    json(conn, RemoteSessionTracker.stop_session())
  end

  operation(:output,
    summary: "Get remote session output",
    description: "Returns recent output lines from the active remote Claude session.",
    tags: ["Remote"],
    parameters: [
      limit: [in: :query, type: :integer, required: false, description: "Max output lines to return (default 200, max 1000)"]
    ],
    responses: [ok: {"Session output", "application/json", %OpenApiSpex.Schema{type: :object}}]
  )
  def output(conn, params) do
    limit =
      case Integer.parse(params["limit"] || "200") do
        {num, _} when num > 0 -> min(num, 1_000)
        _ -> 200
      end

    json(conn, %{
      running: RemoteSessionTracker.status().running,
      lines: RemoteSessionTracker.output(limit)
    })
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
