defmodule CrucibleWeb.Plugs.RBACPropertyTest do
  use CrucibleWeb.ConnCase, async: true
  use ExUnitProperties

  import Crucible.Generators

  alias CrucibleWeb.Plugs.RBAC

  @admin_only_prefixes ~w(
    /api/config /api/logs /api/codebase /api/memory /api/webhooks
    /api/agents /api/router /api/skills /api/tokens /api/remote /api/audit
  )
  @operator_prefixes ~w(/api/traces /api/runs /api/teams /api/workflows /api/research)

  @method_atoms %{
    "GET" => :get,
    "POST" => :post,
    "PUT" => :put,
    "DELETE" => :delete,
    "PATCH" => :patch
  }

  defp conn_as(method_string, path, user_role) do
    method_atom = Map.fetch!(@method_atoms, method_string)

    build_conn(method_atom, path)
    |> assign(:current_user, %{role: user_role})
  end

  defp admin_only_path do
    gen all(
          prefix <- member_of(@admin_only_prefixes),
          suffix <- string(:alphanumeric, max_length: 10)
        ) do
      prefix <> "/" <> suffix
    end
  end

  defp operator_path do
    gen all(
          prefix <- member_of(@operator_prefixes),
          suffix <- string(:alphanumeric, max_length: 10)
        ) do
      prefix <> "/" <> suffix
    end
  end

  defp any_known_path do
    one_of([admin_only_path(), operator_path()])
  end

  describe "admin role" do
    property "admin is never blocked on any path" do
      check all(
              path <- any_known_path(),
              method <- http_method()
            ) do
        conn = conn_as(method, path, "admin") |> RBAC.call([])
        refute conn.halted, "Admin should never be blocked, but was on #{method} #{path}"
      end
    end
  end

  describe "admin-only paths" do
    property "non-admin roles are blocked on admin-only paths" do
      check all(
              path <- admin_only_path(),
              role <- non_admin_role(),
              method <- http_method()
            ) do
        conn = conn_as(method, path, role) |> RBAC.call([])

        assert conn.halted,
               "Role #{role} should be blocked on admin-only path #{path}, but was not"

        assert conn.status == 403
      end
    end
  end

  describe "operator paths" do
    property "operator can GET and POST on operator paths" do
      check all(
              path <- operator_path(),
              method <- http_method()
            ) do
        conn = conn_as(method, path, "operator") |> RBAC.call([])
        refute conn.halted, "Operator should have full access on #{method} #{path}"
      end
    end

    property "viewer can GET operator paths but not write" do
      check all(path <- operator_path()) do
        get_conn = conn_as("GET", path, "viewer") |> RBAC.call([])
        refute get_conn.halted, "Viewer should be allowed GET on #{path}"
      end
    end

    property "viewer is blocked on POST/PUT/DELETE/PATCH to operator paths" do
      check all(
              path <- operator_path(),
              method <- member_of(["POST", "PUT", "DELETE", "PATCH"])
            ) do
        conn = conn_as(method, path, "viewer") |> RBAC.call([])

        assert conn.halted,
               "Viewer should be blocked on #{method} #{path}, but was not"

        assert conn.status == 403
      end
    end
  end
end
