defmodule Crucible.WorkUnitsTest do
  use ExUnit.Case, async: true

  alias Crucible.WorkUnits

  @valid_yaml """
  ```work-units
  - id: backend-api
    description: Implement REST endpoints
    files:
      - lib/router/index.ts
      - lib/router/routes.ts
    acceptanceCriteria:
      - All endpoints return correct status codes
      - Tests pass
  - id: frontend-ui
    description: Build dashboard component
    files:
      - dashboard/web/App.tsx
    dependsOn:
      - backend-api
    acceptanceCriteria:
      - Component renders correctly
  ```
  """

  describe "extract/1" do
    test "parses work units from fenced YAML" do
      units = WorkUnits.extract(@valid_yaml)
      assert length(units) == 2

      [backend, frontend] = units
      assert backend.id == "backend-api"
      assert backend.files == ["lib/router/index.ts", "lib/router/routes.ts"]
      assert length(backend.acceptance_criteria) == 2

      assert frontend.id == "frontend-ui"
      assert frontend.depends_on == ["backend-api"]
    end

    test "returns empty for content without fence" do
      assert [] = WorkUnits.extract("No work units here")
    end

    test "returns empty for invalid YAML" do
      assert [] = WorkUnits.extract("```work-units\n{invalid\n```")
    end

    test "handles snake_case field names" do
      yaml = """
      ```work-units
      - id: test
        description: test unit
        files:
          - lib/test.ts
        acceptance_criteria:
          - works
        context_boundary:
          - lib/
        depends_on:
          - other
        read_files:
          - README.md
      ```
      """

      [unit] = WorkUnits.extract(yaml)
      assert unit.acceptance_criteria == ["works"]
      assert unit.context_boundary == ["lib/"]
      assert unit.depends_on == ["other"]
      assert unit.read_files == ["README.md"]
    end
  end

  describe "validate/1" do
    test "returns empty for valid units" do
      units = WorkUnits.extract(@valid_yaml)
      assert [] = WorkUnits.validate(units)
    end

    test "catches missing files" do
      unit = %{
        id: "test",
        description: "test",
        files: [],
        read_files: [],
        context_boundary: [],
        depends_on: [],
        acceptance_criteria: ["works"]
      }

      errors = WorkUnits.validate([unit])
      assert Enum.any?(errors, &String.contains?(&1, "at least one file"))
    end

    test "catches missing acceptance criteria" do
      unit = %{
        id: "test",
        description: "test",
        files: ["lib/test.ts"],
        read_files: [],
        context_boundary: [],
        depends_on: [],
        acceptance_criteria: []
      }

      errors = WorkUnits.validate([unit])
      assert Enum.any?(errors, &String.contains?(&1, "acceptance criterion"))
    end

    test "catches duplicate IDs" do
      unit = %{
        id: "dup",
        description: "test",
        files: ["lib/test.ts"],
        read_files: [],
        context_boundary: [],
        depends_on: [],
        acceptance_criteria: ["works"]
      }

      errors = WorkUnits.validate([unit, unit])
      assert Enum.any?(errors, &String.contains?(&1, "Duplicate"))
    end

    test "catches dangling depends_on" do
      unit = %{
        id: "test",
        description: "test",
        files: ["lib/test.ts"],
        read_files: [],
        context_boundary: [],
        depends_on: ["nonexistent"],
        acceptance_criteria: ["works"]
      }

      errors = WorkUnits.validate([unit])
      assert Enum.any?(errors, &String.contains?(&1, "unknown unit"))
    end
  end

  describe "format_for_plan/1" do
    test "round-trips through extract" do
      units = WorkUnits.extract(@valid_yaml)
      formatted = WorkUnits.format_for_plan(units)

      assert String.starts_with?(formatted, "```work-units")
      assert String.ends_with?(formatted, "```")

      # Can re-extract
      reparsed = WorkUnits.extract(formatted)
      assert length(reparsed) == length(units)
      assert Enum.map(reparsed, & &1.id) == Enum.map(units, & &1.id)
    end
  end
end
