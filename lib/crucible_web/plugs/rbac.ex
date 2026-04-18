defmodule CrucibleWeb.Plugs.RBAC do
  @moduledoc """
  Role-based access control plug mirroring `dashboard/api/lib/rbac.ts`.

  Roles (hierarchy):
    - admin:    full access to all routes
    - operator: read+write on traces/runs/kanban, blocked on admin-only paths
    - viewer:   read-only (GET) on traces/runs/kanban, blocked on admin-only paths

  Admin-only paths:
    /api/config, /api/logs, /api/codebase, /api/memory, /api/webhooks
  """
  import Plug.Conn

  @behaviour Plug

  @admin_only_prefixes ~w(
    /api/config /api/logs /api/codebase /api/memory /api/webhooks
    /api/agents /api/router /api/skills /api/tokens /api/remote /api/audit
  )
  @operator_prefixes ~w(/api/traces /api/runs /api/teams /api/workflows /api/research)
  @kanban_prefix "/api/kanban"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    user = conn.assigns[:current_user]

    cond do
      is_nil(user) ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{error: "unauthorized", message: "authentication required"})
        )
        |> halt()

      user.role == "admin" ->
        conn

      admin_only?(conn.request_path) ->
        forbidden(conn)

      operator_path?(conn.request_path) ->
        enforce_operator(conn, user.role)

      kanban_path?(conn.request_path) ->
        enforce_operator(conn, user.role)

      true ->
        conn
    end
  end

  defp admin_only?(path) do
    Enum.any?(@admin_only_prefixes, &String.starts_with?(path, &1))
  end

  defp operator_path?(path) do
    Enum.any?(@operator_prefixes, &String.starts_with?(path, &1))
  end

  defp kanban_path?(path), do: String.starts_with?(path, @kanban_prefix)

  # Operators get full read+write access
  defp enforce_operator(conn, "operator"), do: conn

  # Viewers get GET-only access
  defp enforce_operator(conn, "viewer") do
    if conn.method == "GET", do: conn, else: forbidden(conn)
  end

  defp enforce_operator(conn, _role), do: forbidden(conn)

  defp forbidden(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{error: "forbidden", message: "insufficient role"}))
    |> halt()
  end
end
