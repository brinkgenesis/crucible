defmodule Crucible.DagValidationTest do
  use ExUnit.Case, async: true

  alias Crucible.WorkflowRunner

  describe "DAG validation — circular dependencies" do
    test "detects simple A->B->A cycle" do
      config = %{
        "name" => "cyclic",
        "phases" => [
          %{"id" => "a", "name" => "Phase A", "type" => "session", "depends_on" => ["b"]},
          %{"id" => "b", "name" => "Phase B", "type" => "session", "depends_on" => ["a"]}
        ]
      }

      assert {:error, errors} = WorkflowRunner.validate_workflow(config)
      assert Enum.any?(errors, &(&1 =~ "circular dependency"))
    end

    test "detects three-node cycle A->B->C->A" do
      config = %{
        "name" => "tri-cycle",
        "phases" => [
          %{"id" => "a", "depends_on" => ["c"]},
          %{"id" => "b", "depends_on" => ["a"]},
          %{"id" => "c", "depends_on" => ["b"]}
        ]
      }

      assert {:error, errors} = WorkflowRunner.validate_workflow(config)
      assert Enum.any?(errors, &(&1 =~ "circular dependency"))
    end

    test "self-dependency detected as cycle" do
      config = %{
        "name" => "self-dep",
        "phases" => [
          %{"id" => "a", "depends_on" => ["a"]}
        ]
      }

      assert {:error, errors} = WorkflowRunner.validate_workflow(config)
      assert Enum.any?(errors, &(&1 =~ "circular dependency"))
    end

    test "accepts valid linear dependency chain" do
      config = %{
        "name" => "linear",
        "phases" => [
          %{"id" => "a", "name" => "Phase A"},
          %{"id" => "b", "name" => "Phase B", "depends_on" => ["a"]},
          %{"id" => "c", "name" => "Phase C", "depends_on" => ["b"]}
        ]
      }

      assert :ok = WorkflowRunner.validate_workflow(config)
    end

    test "accepts diamond dependency (A->B, A->C, B->D, C->D)" do
      config = %{
        "name" => "diamond",
        "phases" => [
          %{"id" => "a", "name" => "A"},
          %{"id" => "b", "name" => "B", "depends_on" => ["a"]},
          %{"id" => "c", "name" => "C", "depends_on" => ["a"]},
          %{"id" => "d", "name" => "D", "depends_on" => ["b", "c"]}
        ]
      }

      assert :ok = WorkflowRunner.validate_workflow(config)
    end

    test "accepts phases with no dependencies" do
      config = %{
        "name" => "independent",
        "phases" => [
          %{"id" => "a"},
          %{"id" => "b"},
          %{"id" => "c"}
        ]
      }

      assert :ok = WorkflowRunner.validate_workflow(config)
    end
  end

  describe "DAG validation — unknown references" do
    test "detects reference to unknown phase" do
      config = %{
        "name" => "bad-ref",
        "phases" => [
          %{"id" => "a", "depends_on" => ["nonexistent"]}
        ]
      }

      assert {:error, errors} = WorkflowRunner.validate_workflow(config)
      assert Enum.any?(errors, &(&1 =~ "unknown phase"))
    end

    test "allows reference by name (camelCase phaseName)" do
      config = %{
        "name" => "name-ref",
        "phases" => [
          %{"id" => "phase-0", "phaseName" => "build"},
          %{"id" => "phase-1", "phaseName" => "test", "dependsOn" => ["build"]}
        ]
      }

      assert :ok = WorkflowRunner.validate_workflow(config)
    end

    test "allows reference by name (snake_case)" do
      config = %{
        "name" => "name-ref-snake",
        "phases" => [
          %{"id" => "p0", "name" => "setup"},
          %{"id" => "p1", "name" => "deploy", "depends_on" => ["setup"]}
        ]
      }

      assert :ok = WorkflowRunner.validate_workflow(config)
    end
  end

  describe "DAG validation — duplicate phase names" do
    test "detects duplicate phase names" do
      config = %{
        "name" => "dupes",
        "phases" => [
          %{"id" => "a", "name" => "deploy"},
          %{"id" => "b", "name" => "deploy"}
        ]
      }

      assert {:error, errors} = WorkflowRunner.validate_workflow(config)
      assert Enum.any?(errors, &(&1 =~ "duplicate phase names"))
    end

    test "allows unique names" do
      config = %{
        "name" => "unique-names",
        "phases" => [
          %{"id" => "a", "name" => "build"},
          %{"id" => "b", "name" => "test"},
          %{"id" => "c", "name" => "deploy"}
        ]
      }

      assert :ok = WorkflowRunner.validate_workflow(config)
    end
  end

  describe "DAG validation — edge cases" do
    test "handles empty depends_on list" do
      config = %{
        "name" => "empty-deps",
        "phases" => [
          %{"id" => "a", "depends_on" => []}
        ]
      }

      assert :ok = WorkflowRunner.validate_workflow(config)
    end

    test "handles missing depends_on field" do
      config = %{
        "name" => "no-deps",
        "phases" => [
          %{"id" => "a", "type" => "session"}
        ]
      }

      assert :ok = WorkflowRunner.validate_workflow(config)
    end

    test "handles single phase with no dependencies" do
      config = %{
        "name" => "single",
        "phases" => [%{"id" => "solo"}]
      }

      assert :ok = WorkflowRunner.validate_workflow(config)
    end

    test "auto-generated phase IDs work with depends_on" do
      config = %{
        "name" => "auto-ids",
        "phases" => [
          %{"name" => "first"},
          %{"name" => "second", "depends_on" => ["first"]}
        ]
      }

      # "first" is a name, not an id — should resolve
      assert :ok = WorkflowRunner.validate_workflow(config)
    end

    test "mixed id and name references work" do
      config = %{
        "name" => "mixed-refs",
        "phases" => [
          %{"id" => "phase-a", "name" => "Build"},
          %{"id" => "phase-b", "name" => "Test", "depends_on" => ["phase-a"]},
          %{"id" => "phase-c", "name" => "Deploy", "depends_on" => ["Test"]}
        ]
      }

      assert :ok = WorkflowRunner.validate_workflow(config)
    end
  end
end
