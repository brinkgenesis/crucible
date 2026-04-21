defmodule Crucible.RoleAssignmentTest do
  use ExUnit.Case, async: true

  alias Crucible.RoleAssignment

  describe "classify_file/1" do
    test "classifies frontend files" do
      assert :coder_frontend = RoleAssignment.classify_file("dashboard/web/App.tsx")
      assert :coder_frontend = RoleAssignment.classify_file("dashboard/web/components/Button.tsx")
      assert :coder_frontend = RoleAssignment.classify_file("styles/main.css")
    end

    test "classifies runtime files" do
      assert :coder_runtime = RoleAssignment.classify_file(".claude/hooks/cost-tracker.sh")
      assert :coder_runtime = RoleAssignment.classify_file("scripts/deploy.sh")
      assert :coder_runtime = RoleAssignment.classify_file("lib/cli/self-improvement/kpi.ts")
      assert :coder_runtime = RoleAssignment.classify_file("monitoring/grafana.json")
    end

    test "classifies backend files" do
      assert :coder_backend = RoleAssignment.classify_file("dashboard/api/server.ts")
      assert :coder_backend = RoleAssignment.classify_file("lib/router/index.ts")
      assert :coder_backend = RoleAssignment.classify_file("lib/memory/vault.ts")
      assert :coder_backend = RoleAssignment.classify_file("lib/db/schema.ts")
    end

    test "defaults to backend for unknown paths" do
      assert :coder_backend = RoleAssignment.classify_file("some/random/file.ts")
    end
  end

  describe "assign_files/1" do
    test "assigns files to roles with zero overlap" do
      files = [
        "dashboard/web/App.tsx",
        "lib/router/index.ts",
        ".claude/hooks/test.sh",
        "lib/memory/vault.ts"
      ]

      result = RoleAssignment.assign_files(files)
      assert :coder_frontend in Map.keys(result)
      assert :coder_backend in Map.keys(result)
      assert :coder_runtime in Map.keys(result)

      all_assigned = result |> Map.values() |> List.flatten()
      assert length(all_assigned) == length(Enum.uniq(all_assigned))
    end

    test "deduplicates files" do
      files = ["lib/router/index.ts", "lib/router/index.ts"]
      result = RoleAssignment.assign_files(files)
      all = result |> Map.values() |> List.flatten()
      assert length(all) == 1
    end
  end

  describe "dominant_role/1" do
    test "returns majority role" do
      files = [
        "lib/router/index.ts",
        "lib/memory/vault.ts",
        "lib/db/schema.ts"
      ]

      assert :coder_backend = RoleAssignment.dominant_role(files)
    end

    test "excludes test files from voting" do
      files = [
        "tests/router.test.ts",
        "tests/memory.test.ts",
        ".claude/hooks/test.sh"
      ]

      assert :coder_runtime = RoleAssignment.dominant_role(files)
    end

    test "returns backend as default for empty" do
      assert :coder_backend = RoleAssignment.dominant_role([])
    end
  end

  describe "resolve_work_assignments/2" do
    test "assigns work units to available roles" do
      units = [
        %{id: "api", files: ["lib/router/index.ts", "lib/router/routes.ts"]},
        %{id: "ui", files: ["dashboard/web/App.tsx"]},
        %{id: "hooks", files: [".claude/hooks/test.sh"]}
      ]

      roles = [:coder_backend, :coder_frontend, :coder_runtime]
      result = RoleAssignment.resolve_work_assignments(units, roles)

      assert length(result[:coder_backend]) == 1
      assert length(result[:coder_frontend]) == 1
      assert length(result[:coder_runtime]) == 1
    end

    test "load-balances when preferred role unavailable" do
      units = [
        %{id: "api1", files: ["lib/router/index.ts"]},
        %{id: "api2", files: ["lib/db/schema.ts"]}
      ]

      # Only one role available
      roles = [:coder_backend]
      result = RoleAssignment.resolve_work_assignments(units, roles)

      assert length(result[:coder_backend]) == 2
    end
  end

  describe "extract_plan_files/1" do
    test "extracts file paths from plan content" do
      content = """
      We need to modify `lib/router/index.ts` and `dashboard/web/App.tsx`.
      Also update `scripts/deploy.sh`.
      """

      files = RoleAssignment.extract_plan_files(content)
      assert "lib/router/index.ts" in files
      assert "dashboard/web/App.tsx" in files
      assert "scripts/deploy.sh" in files
    end
  end

  describe "normalize_path/1" do
    test "strips backticks" do
      assert "lib/test.ts" = RoleAssignment.normalize_path("`lib/test.ts`")
    end

    test "strips absolute path prefix" do
      assert "lib/test.ts" = RoleAssignment.normalize_path("/home/user/project/lib/test.ts")
    end
  end

  describe "role_profile/1" do
    test "returns profile for known roles" do
      profile = RoleAssignment.role_profile(:coder_backend)
      assert profile.name == "Backend Engineer"
    end

    test "returns default for unknown roles" do
      profile = RoleAssignment.role_profile(:unknown)
      assert profile.name == "Engineer"
    end
  end
end
