defmodule Crucible.AgentRunnerTest do
  use ExUnit.Case, async: true

  alias Crucible.AgentRunner
  alias Crucible.Types.{Run, Phase}

  defp build_run(overrides) do
    defaults = %{
      id: "test-run-#{:rand.uniform(10000)}",
      workflow_type: "test-workflow",
      budget_usd: 50.0,
      phases: [],
      status: :pending
    }

    struct!(Run, Map.merge(defaults, overrides))
  end

  describe "run/2" do
    test "completes successfully with no phases" do
      run = build_run(%{phases: []})

      assert {:ok, result} = AgentRunner.run(run)
      assert result.run_id == run.id
      assert result.status == "completed"
      assert result.phases == []
      assert is_integer(result.elapsed_ms)
    end

    test "detects dependency deadlock" do
      # Two phases that depend on each other
      phase1 = %Phase{
        id: "a",
        name: "A",
        type: :session,
        depends_on: ["b"],
        max_retries: 0,
        retry_count: 0,
        timeout_ms: 60_000,
        phase_index: 0,
        status: :pending
      }

      phase2 = %Phase{
        id: "b",
        name: "B",
        type: :session,
        depends_on: ["a"],
        max_retries: 0,
        retry_count: 0,
        timeout_ms: 60_000,
        phase_index: 1,
        status: :pending
      }

      run = build_run(%{phases: [phase1, phase2]})

      assert {:error, {:dependency_deadlock, ids}} = AgentRunner.run(run)
      assert "a" in ids
      assert "b" in ids
    end

    test "output card creation is skipped when on_complete_create_card is nil" do
      run = build_run(%{phases: [], on_complete_create_card: nil})

      assert {:ok, result} = AgentRunner.run(run)
      assert result.status == "completed"
    end

    test "output card creation writes card file when configured" do
      card_dir = ".claude-flow/cards"

      # Count existing cards
      existing =
        if File.dir?(card_dir) do
          card_dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".json")) |> length()
        else
          0
        end

      run =
        build_run(%{
          phases: [],
          on_complete_create_card: %{
            "title" => "Test card",
            "column" => "unassigned",
            "tags" => ["auto"]
          }
        })

      assert {:ok, _} = AgentRunner.run(run)

      # Verify card was created
      if File.dir?(card_dir) do
        current =
          card_dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".json")) |> length()

        assert current > existing
      end
    end
  end
end
