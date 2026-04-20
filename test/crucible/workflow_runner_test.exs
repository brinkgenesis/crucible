defmodule Crucible.WorkflowRunnerTest do
  use ExUnit.Case, async: true

  alias Crucible.WorkflowRunner
  alias Crucible.Types.{Run, Phase, WorkUnit}

  describe "create_run/2" do
    test "creates run from workflow config" do
      config = %{
        "name" => "test-workflow",
        "budget_usd" => 25.0,
        "phases" => [
          %{
            "id" => "plan",
            "name" => "Planning",
            "type" => "session",
            "prompt" => "Plan the implementation",
            "max_retries" => 3
          },
          %{
            "id" => "implement",
            "name" => "Implementation",
            "type" => "team",
            "depends_on" => ["plan"],
            "work_units" => [
              %{"path" => "lib/foo.ex", "role" => "coder"},
              "lib/bar.ex"
            ]
          }
        ]
      }

      assert {:ok, %Run{} = run} = WorkflowRunner.create_run(config)
      assert run.workflow_type == "test-workflow"
      assert run.budget_usd == 25.0
      assert length(run.phases) == 2

      [plan, impl] = run.phases
      assert %Phase{id: "plan", name: "Planning", type: :session, max_retries: 3} = plan
      assert plan.prompt == "Plan the implementation"

      assert %Phase{id: "implement", type: :team, depends_on: ["plan"]} = impl
      assert length(impl.work_units) == 2
      assert %WorkUnit{path: "lib/foo.ex", role: "coder"} = hd(impl.work_units)
    end

    test "creates run with custom overrides" do
      config = %{"name" => "simple", "phases" => [%{"type" => "session"}]}

      assert {:ok, run} =
               WorkflowRunner.create_run(config,
                 run_id: "custom-id",
                 budget_usd: 5.0,
                 branch: "feature/test",
                 plan_summary: "Do the thing"
               )

      assert run.id == "custom-id"
      assert run.budget_usd == 5.0
      assert run.branch == "feature/test"
      assert run.plan_summary == "Do the thing"
    end

    test "rejects empty phases" do
      assert {:error, errors} = WorkflowRunner.create_run(%{"name" => "empty"})
      assert "workflow must have at least one phase" in errors
    end

    test "rejects invalid phase types" do
      config = %{"name" => "t", "phases" => [%{"type" => "unknown"}]}
      assert {:error, errors} = WorkflowRunner.create_run(config)
      assert Enum.any?(errors, &String.contains?(&1, "invalid type"))
    end

    test "parses all valid phase types" do
      types = ~w(session team review-gate pr-shepherd preflight)
      expected = [:session, :team, :review_gate, :pr_shepherd, :preflight]

      for {type, expected_type} <- Enum.zip(types, expected) do
        config = %{"name" => "t", "phases" => [%{"type" => type}]}
        {:ok, run} = WorkflowRunner.create_run(config)
        assert hd(run.phases).type == expected_type
      end
    end

    test "parses phaseName (camelCase from TS manifests) as phase name" do
      config = %{
        "name" => "coding-sprint",
        "phases" => [
          %{"phaseName" => "sprint", "type" => "team"},
          %{"phaseName" => "pr-shepherd", "type" => "pr-shepherd", "dependsOn" => ["sprint"]}
        ]
      }

      {:ok, run} = WorkflowRunner.create_run(config)
      [sprint, shepherd] = run.phases
      assert sprint.name == "sprint"
      assert shepherd.name == "pr-shepherd"
      assert shepherd.depends_on == ["sprint"]
    end

    test "rejects missing workflow name" do
      config = %{"phases" => [%{"type" => "session"}]}
      assert {:error, errors} = WorkflowRunner.create_run(config)
      assert Enum.any?(errors, &String.contains?(&1, "name"))
    end

    test "rejects non-map config" do
      assert {:error, :invalid_workflow_config} = WorkflowRunner.create_run("not a map")
    end
  end

  describe "select_workflow/2" do
    test "matches workflow by name keywords" do
      workflows = [
        %{"name" => "bug-fix", "keywords" => ["debug", "repair"]},
        %{"name" => "feature-add", "keywords" => ["implement", "build"]},
        %{"name" => "refactor", "keywords" => ["cleanup", "restructure"]}
      ]

      assert {:ok, "bug-fix"} = WorkflowRunner.select_workflow("fix a debug issue", workflows)

      assert {:ok, "feature-add"} =
               WorkflowRunner.select_workflow("implement new feature", workflows)

      assert {:ok, "refactor"} = WorkflowRunner.select_workflow("cleanup the code", workflows)
    end

    test "returns no_match when no keywords hit" do
      workflows = [%{"name" => "deploy", "keywords" => ["ship", "release"]}]
      assert {:error, :no_match} = WorkflowRunner.select_workflow("write tests", workflows)
    end

    test "prefers keyword matches over name matches" do
      workflows = [
        %{"name" => "test-runner", "keywords" => []},
        %{"name" => "other", "keywords" => ["test", "runner"]}
      ]

      # "other" has keyword matches (2x weight) so it should win
      assert {:ok, "other"} = WorkflowRunner.select_workflow("run the test runner", workflows)
    end
  end

  describe "scale_agents/2" do
    @backend %{role: "coder-backend", name: "Ava"}
    @runtime %{role: "coder-runtime", name: "Marco"}
    @frontend %{role: "coder-frontend", name: "Lena"}
    @reviewer %{role: "reviewer", name: "Rev"}

    test "nil complexity returns full roster" do
      agents = [@backend, @runtime, @frontend]
      assert WorkflowRunner.scale_agents(agents, nil) == agents
    end

    test "complexity 1 returns single worker" do
      agents = [@backend, @runtime, @frontend]
      assert WorkflowRunner.scale_agents(agents, 1) == [@backend]
    end

    test "complexity 2 returns two workers" do
      agents = [@backend, @runtime, @frontend]
      assert WorkflowRunner.scale_agents(agents, 2) == [@backend, @runtime]
    end

    test "complexity 3 returns all three workers" do
      agents = [@backend, @runtime, @frontend]
      assert WorkflowRunner.scale_agents(agents, 3) == agents
    end

    test "reviewer is always kept regardless of complexity" do
      agents = [@backend, @runtime, @frontend, @reviewer]
      result = WorkflowRunner.scale_agents(agents, 1)
      assert result == [@backend, @reviewer]
    end

    test "complexity 2 with reviewer keeps two workers plus reviewer" do
      agents = [@backend, @runtime, @frontend, @reviewer]
      result = WorkflowRunner.scale_agents(agents, 2)
      assert result == [@backend, @runtime, @reviewer]
    end

    test "complexity exceeding roster size returns all workers" do
      agents = [@backend, @runtime]
      assert WorkflowRunner.scale_agents(agents, 5) == agents
    end

    test "complexity 0 returns full roster unchanged" do
      agents = [@backend, @runtime]
      assert WorkflowRunner.scale_agents(agents, 0) == agents
    end
  end

  describe "create_run with complexity scaling" do
    test "complexity 1 scales team phase to single agent" do
      config = %{
        "name" => "sprint",
        "complexity" => 1,
        "phases" => [
          %{
            "type" => "team",
            "agents" => [
              %{"role" => "coder-backend"},
              %{"role" => "coder-runtime"},
              %{"role" => "coder-frontend"}
            ]
          }
        ]
      }

      {:ok, run} = WorkflowRunner.create_run(config)
      assert run.complexity == 1
      [phase] = run.phases
      assert length(phase.agents) == 1
      assert hd(phase.agents).role == "coder-backend"
    end

    test "complexity 2 scales team phase to two agents" do
      config = %{
        "name" => "sprint",
        "complexity" => 2,
        "phases" => [
          %{
            "type" => "team",
            "agents" => [
              %{"role" => "coder-backend"},
              %{"role" => "coder-runtime"},
              %{"role" => "coder-frontend"}
            ]
          }
        ]
      }

      {:ok, run} = WorkflowRunner.create_run(config)
      assert run.complexity == 2
      [phase] = run.phases
      assert length(phase.agents) == 2
      roles = Enum.map(phase.agents, & &1.role)
      assert roles == ["coder-backend", "coder-runtime"]
    end

    test "no complexity leaves all agents" do
      config = %{
        "name" => "sprint",
        "phases" => [
          %{
            "type" => "team",
            "agents" => [
              %{"role" => "coder-backend"},
              %{"role" => "coder-runtime"},
              %{"role" => "coder-frontend"}
            ]
          }
        ]
      }

      {:ok, run} = WorkflowRunner.create_run(config)
      assert run.complexity == nil
      [phase] = run.phases
      assert length(phase.agents) == 3
    end

    test "complexity does not affect session phases" do
      config = %{
        "name" => "sprint",
        "complexity" => 1,
        "phases" => [
          %{
            "type" => "session",
            "agents" => [
              %{"role" => "coder-backend"},
              %{"role" => "coder-runtime"}
            ]
          }
        ]
      }

      {:ok, run} = WorkflowRunner.create_run(config)
      [phase] = run.phases
      assert length(phase.agents) == 2
    end
  end

  describe "preflight_team_roles/1" do
    test "passes for team phases with roles" do
      phases = [
        %Phase{
          id: "impl",
          type: :team,
          work_units: [
            %WorkUnit{id: "wu-0", path: "lib/a.ex", role: "coder"},
            %WorkUnit{id: "wu-1", path: "lib/b.ex", role: "reviewer"}
          ]
        }
      ]

      assert :ok = WorkflowRunner.preflight_team_roles(phases)
    end

    test "passes for non-team phases without roles" do
      phases = [
        %Phase{id: "plan", type: :session, work_units: []}
      ]

      assert :ok = WorkflowRunner.preflight_team_roles(phases)
    end

    test "fails for team phase with no work_units" do
      phases = [%Phase{id: "impl", type: :team, work_units: []}]

      assert {:error, errors} = WorkflowRunner.preflight_team_roles(phases)
      assert Enum.any?(errors, &String.contains?(&1, "at least one work_unit"))
    end

    test "fails for work_unit missing role" do
      phases = [
        %Phase{
          id: "impl",
          type: :team,
          work_units: [%WorkUnit{id: "wu-0", path: "lib/a.ex", role: nil}]
        }
      ]

      assert {:error, errors} = WorkflowRunner.preflight_team_roles(phases)
      assert Enum.any?(errors, &String.contains?(&1, "missing role"))
    end

    test "fails for work_unit missing path" do
      phases = [
        %Phase{
          id: "impl",
          type: :team,
          work_units: [%WorkUnit{id: "wu-0", path: "", role: "coder"}]
        }
      ]

      assert {:error, errors} = WorkflowRunner.preflight_team_roles(phases)
      assert Enum.any?(errors, &String.contains?(&1, "missing path"))
    end
  end
end
